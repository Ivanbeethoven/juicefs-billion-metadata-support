# References

这些链接用于解释选型依据。实际生产配置仍需结合业务 QPS、目录结构、文件大小分布和压测结果调整。

## JuiceFS

- JuiceFS v0.16 release: TiKV metadata engine  
  https://juicefs.com/en/blog/release-notes/juicefs-release-v016
- Guidance on selecting metadata engine in JuiceFS  
  https://juicefs.com/en/blog/usage-tips/juicefs-metadata-engine-selection-guide
- Metadata Engines Benchmark  
  https://juicefs.com/docs/community/metadata_engines_benchmark/
- How to Set Up Metadata Engine  
  https://juicefs.com/docs/community/databases_for_metadata/

## TiKV / TiDB

- TiDB hardware and software requirements  
  https://docs.pingcap.com/tidb/stable/hardware-and-software-requirements
- TiKV prerequisites  
  https://tikv.org/docs/6.1/deploy/install/prerequisites/

## Aerospike

- Capacity planning guide: https://aerospike.com/docs/database/manage/planning/capacity/
- System limits and thresholds: https://aerospike.com/docs/database/reference/limitations/
- Primary index architecture: https://aerospike.com/docs/database/learn/architecture/data-storage/primary-index/
- Secondary index capacity planning: https://aerospike.com/docs/database/manage/planning/capacity/secondary-indexes/

## RustFS

- RustFS Documentation  
  https://docs.rustfs.com/
- RustFS Amazon S3 Compatibility  
  https://docs.rustfs.com/features/s3-compatibility/
