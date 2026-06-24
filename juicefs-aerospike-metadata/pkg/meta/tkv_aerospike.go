//go:build !noaerospike
// +build !noaerospike

/*
 * JuiceFS, Copyright 2020 Juicedata, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package meta

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	as "github.com/aerospike/aerospike-client-go/v7"
	"github.com/google/uuid"
)

const (
	aeroKeyBin   = "k"
	aeroValueBin = "v"
	aeroVerBin   = "r"
)

type aerospikeTxn struct {
	ctx      context.Context
	client   *aerospikeClient
	observed map[string]int64
	buffer   map[string][]byte
}

func (tx *aerospikeTxn) get(key []byte) []byte {
	k := string(key)
	if v, ok := tx.buffer[k]; ok {
		return v
	}
	value, ver, ok, err := tx.client.get(key)
	if err != nil {
		panic(err)
	}
	if !ok {
		tx.observed[k] = 0
		return nil
	}
	tx.observed[k] = ver
	return value
}

func (tx *aerospikeTxn) gets(keys ...[]byte) [][]byte {
	values := make([][]byte, len(keys))
	for i, key := range keys {
		values[i] = tx.get(key)
	}
	return values
}

func (tx *aerospikeTxn) scan(begin, end []byte, keysOnly bool, handler func(k, v []byte) bool) {
	rows, err := tx.client.scanRange(begin, end)
	if err != nil {
		panic(err)
	}
	for _, row := range rows {
		tx.observed[string(row.key)] = row.ver
		value := row.value
		if keysOnly {
			value = nil
		}
		if !handler(row.key, value) {
			break
		}
	}
}

func (tx *aerospikeTxn) exist(prefix []byte) bool {
	rows, err := tx.client.scanRange(prefix, nextKey(prefix))
	if err != nil {
		panic(err)
	}
	for _, row := range rows {
		tx.observed[string(row.key)] = row.ver
		return true
	}
	return false
}

func (tx *aerospikeTxn) set(key, value []byte) {
	v := make([]byte, len(value))
	copy(v, value)
	tx.buffer[string(key)] = v
}

func (tx *aerospikeTxn) append(key []byte, value []byte) {
	tx.set(key, append(tx.get(key), value...))
}

func (tx *aerospikeTxn) incrBy(key []byte, value int64) int64 {
	newValue := parseCounter(tx.get(key))
	if value != 0 {
		newValue += value
		tx.set(key, packCounter(newValue))
	}
	return newValue
}

func (tx *aerospikeTxn) delete(key []byte) {
	tx.buffer[string(key)] = nil
}

type aerospikeRow struct {
	key   []byte
	value []byte
	ver   int64
}

type aerospikeClient struct {
	client *as.Client
	ns     string
	set    string
}

func (c *aerospikeClient) name() string {
	return "aerospike"
}

func (c *aerospikeClient) shouldRetry(err error) bool {
	return errorsIsConflict(err)
}

func (c *aerospikeClient) config(key string) interface{} {
	return nil
}

func (c *aerospikeClient) simpleTxn(ctx context.Context, f func(*kvTxn) error, retry int) error {
	return c.txn(ctx, f, retry)
}

func (c *aerospikeClient) txn(ctx context.Context, f func(*kvTxn) error, retry int) (err error) {
	tx := &aerospikeTxn{
		ctx:      ctx,
		client:   c,
		observed: make(map[string]int64),
		buffer:   make(map[string][]byte),
	}
	defer func() {
		if r := recover(); r != nil {
			if fe, ok := r.(error); ok {
				err = fe
			} else {
				panic(r)
			}
		}
	}()
	if err = f(&kvTxn{tx, retry}); err != nil {
		return err
	}
	if len(tx.buffer) == 0 {
		return nil
	}
	return c.commit(ctx, tx)
}

func (c *aerospikeClient) scan(prefix []byte, handler func(key []byte, value []byte) bool) error {
	rows, err := c.scanRange(prefix, nextKey(prefix))
	if err != nil {
		return err
	}
	for _, row := range rows {
		if !handler(row.key, row.value) {
			break
		}
	}
	return nil
}

func (c *aerospikeClient) reset(prefix []byte) error {
	rows, err := c.scanRange(prefix, scanEnd(prefix))
	if err != nil {
		return err
	}
	for _, row := range rows {
		key, err := c.key(row.key)
		if err != nil {
			return err
		}
		if _, err = c.client.Delete(nil, key); err != nil {
			return err
		}
	}
	return nil
}

func (c *aerospikeClient) close() error {
	c.client.Close()
	return nil
}

func (c *aerospikeClient) gc() {}

func (c *aerospikeClient) key(key []byte) (*as.Key, error) {
	return as.NewKey(c.ns, c.set, base64.RawURLEncoding.EncodeToString(key))
}

func (c *aerospikeClient) lockKey() (*as.Key, error) {
	return as.NewKey(c.ns, c.set+"_locks", "global")
}

func (c *aerospikeClient) get(key []byte) ([]byte, int64, bool, error) {
	ak, err := c.key(key)
	if err != nil {
		return nil, 0, false, err
	}
	record, err := c.client.Get(nil, ak, aeroValueBin, aeroVerBin)
	if err != nil {
		if strings.Contains(err.Error(), "KEY_NOT_FOUND") {
			return nil, 0, false, nil
		}
		return nil, 0, false, err
	}
	if record == nil {
		return nil, 0, false, nil
	}
	value, _ := record.Bins[aeroValueBin].([]byte)
	ver, err := int64FromBin(record.Bins[aeroVerBin])
	if err != nil {
		return nil, 0, false, err
	}
	return value, ver, true, nil
}

func (c *aerospikeClient) scanRange(begin, end []byte) ([]aerospikeRow, error) {
	rs, err := c.client.ScanAll(nil, c.ns, c.set, aeroKeyBin, aeroValueBin, aeroVerBin)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	var rows []aerospikeRow
	for res := range rs.Results() {
		if res.Err != nil {
			return nil, res.Err
		}
		if res.Record == nil {
			continue
		}
		key, _ := res.Record.Bins[aeroKeyBin].([]byte)
		if len(key) == 0 || bytes.Compare(key, begin) < 0 || (end != nil && bytes.Compare(key, end) >= 0) {
			continue
		}
		value, _ := res.Record.Bins[aeroValueBin].([]byte)
		ver, err := int64FromBin(res.Record.Bins[aeroVerBin])
		if err != nil {
			return nil, err
		}
		rows = append(rows, aerospikeRow{key: key, value: value, ver: ver})
	}
	sort.Slice(rows, func(i, j int) bool {
		return bytes.Compare(rows[i].key, rows[j].key) < 0
	})
	return rows, nil
}

func (c *aerospikeClient) commit(ctx context.Context, tx *aerospikeTxn) error {
	owner, err := c.acquireLock(ctx)
	if err != nil {
		return err
	}
	defer func() {
		if err := c.releaseLock(owner); err != nil {
			logger.Warnf("release aerospike metadata lock: %s", err)
		}
	}()
	for k, expected := range tx.observed {
		_, current, ok, err := c.get([]byte(k))
		if err != nil {
			return err
		}
		if !ok {
			current = 0
		}
		if current != expected {
			return conflicted
		}
	}
	for k, value := range tx.buffer {
		keyBytes := []byte(k)
		ak, err := c.key(keyBytes)
		if err != nil {
			return err
		}
		if value == nil {
			if _, err = c.client.Delete(nil, ak); err != nil {
				return err
			}
			continue
		}
		wp := as.NewWritePolicy(0, as.TTLDontExpire)
		if err = c.client.PutBins(wp, ak,
			as.NewBin(aeroKeyBin, keyBytes),
			as.NewBin(aeroValueBin, value),
			as.NewBin(aeroVerBin, tx.observed[k]+1),
		); err != nil {
			return err
		}
	}
	return nil
}

func (c *aerospikeClient) acquireLock(ctx context.Context) (string, error) {
	owner := uuid.NewString()
	key, err := c.lockKey()
	if err != nil {
		return "", err
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		wp := as.NewWritePolicy(0, 30)
		wp.RecordExistsAction = as.CREATE_ONLY
		err = c.client.PutBins(wp, key, as.NewBin("owner", owner))
		if err == nil {
			return owner, nil
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("timeout acquiring aerospike metadata lock: %s", err)
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (c *aerospikeClient) releaseLock(owner string) error {
	key, err := c.lockKey()
	if err != nil {
		return err
	}
	_, err = c.client.Delete(nil, key)
	return err
}

func int64FromBin(v interface{}) (int64, error) {
	switch n := v.(type) {
	case int:
		return int64(n), nil
	case int64:
		return n, nil
	case int32:
		return int64(n), nil
	case nil:
		return 0, nil
	default:
		return 0, fmt.Errorf("invalid aerospike int bin %T", v)
	}
}

func newAerospikeClient(addr string) (tkvClient, error) {
	u, err := url.Parse("aerospike://" + addr)
	if err != nil {
		return nil, err
	}
	host := u.Hostname()
	port := 3000
	if u.Port() != "" {
		port, err = strconv.Atoi(u.Port())
		if err != nil {
			return nil, err
		}
	}
	if host == "" {
		host = "127.0.0.1"
	}
	ns := strings.Trim(u.Path, "/")
	if ns == "" {
		ns = "test"
	}
	set := u.Query().Get("set")
	if set == "" {
		set = "juicefs"
	}
	if _, _, err := net.SplitHostPort(u.Host); err != nil && strings.Contains(u.Host, ":") {
		return nil, err
	}
	client, err := as.NewClient(host, port)
	if err != nil {
		return nil, err
	}
	return &aerospikeClient{client: client, ns: ns, set: set}, nil
}

func init() {
	Register("aerospike", newKVMeta)
	drivers["aerospike"] = newAerospikeClient
}

func errorsIsConflict(err error) bool {
	return errors.Is(err, conflicted)
}

func scanEnd(prefix []byte) []byte {
	if len(prefix) == 0 {
		return nil
	}
	return nextKey(prefix)
}
