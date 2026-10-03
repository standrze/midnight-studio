# Third-party notices

Midnight Studio's own source is distributed under [Apache License 2.0](LICENSE).
Third-party code retains its upstream licenses and notices. This index was
checked against the local dependency checkouts at the revisions recorded in
[Package.resolved](Package.resolved) and
[Workers/Package.resolved](Workers/Package.resolved).

## Terminal interface

The terminal interface uses loom 0.1.1 and weft 0.1.1, both distributed under
Apache 2.0. Their exact revisions and the added swift-markdown/swift-cmark
resolution are recorded in Package.resolved. Dependencies retain their bundled
licenses; no terminal library source was copied into Studio.

## Web application

The direct dependency is Hummingbird 2.26.0, copyright 2024 The Hummingbird
Project. The table includes its resolved dependencies, including packages used
by the web tests. Links identify the exact checked-out revision.

| Package | Version | Package license | Upstream notices |
| --- | --- | --- | --- |
| async-http-client | 1.36.1 | [Apache 2.0](https://github.com/swift-server/async-http-client/blob/f95c908967e98c68c5ce3fd61a7974e7e869e303/LICENSE.txt) | [NOTICE](https://github.com/swift-server/async-http-client/blob/f95c908967e98c68c5ce3fd61a7974e7e869e303/NOTICE.txt) |
| hummingbird | 2.26.0 | [Apache 2.0](https://github.com/hummingbird-project/hummingbird/blob/55bc9025a4825ee2a234b1f82b51b87be6ef74e4/LICENSE.txt) | [NOTICE](https://github.com/hummingbird-project/hummingbird/blob/55bc9025a4825ee2a234b1f82b51b87be6ef74e4/NOTICE.txt) |
| swift-algorithms | 1.2.1 | [Apache 2.0 + Swift exception](https://github.com/apple/swift-algorithms/blob/87e50f483c54e6efd60e885f7f5aa946cee68023/LICENSE.txt) | — |
| swift-asn1 | 1.7.2 | [Apache 2.0](https://github.com/apple/swift-asn1/blob/d9a5b37470adc940d22c3bcd5ca6953a516b727f/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-asn1/blob/d9a5b37470adc940d22c3bcd5ca6953a516b727f/NOTICE.txt) |
| swift-async-algorithms | 1.1.5 | [Apache 2.0 + Swift exception](https://github.com/apple/swift-async-algorithms/blob/3da39bbc4e687d4192af7c9cf4eab805745a0b9c/LICENSE.txt) | — |
| swift-atomics | 1.3.1 | [Apache 2.0 + Swift exception](https://github.com/apple/swift-atomics/blob/0442cb5a3f98ab802acb777929fdb446bda11a34/LICENSE.txt) | — |
| swift-certificates | 1.20.0 | [Apache 2.0](https://github.com/apple/swift-certificates/blob/c8aece90ea05f9866bd392a5bf13b5cae56c0e03/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-certificates/blob/c8aece90ea05f9866bd392a5bf13b5cae56c0e03/NOTICE.txt) |
| swift-collections | 1.6.0 | [Apache 2.0 + Swift exception](https://github.com/apple/swift-collections/blob/a0cb0954ecb21e4e31b0070e6ed5674e8556685a/LICENSE.txt) | — |
| swift-configuration | 1.2.0 | [Apache 2.0](https://github.com/apple/swift-configuration/blob/be76c4ad929eb6c4bcaf3351799f2adf9e6848a9/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-configuration/blob/be76c4ad929eb6c4bcaf3351799f2adf9e6848a9/NOTICE.txt) |
| swift-crypto | 4.5.2 | [Apache 2.0](https://github.com/apple/swift-crypto/blob/da9d28d69ebe3894b18376c8f2395c2f37b8448f/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-crypto/blob/da9d28d69ebe3894b18376c8f2395c2f37b8448f/NOTICE.txt) |
| swift-distributed-tracing | 1.4.1 | [Apache 2.0](https://github.com/apple/swift-distributed-tracing/blob/dc4030184203ffafbb2ec614352487235d747fe0/LICENSE.txt) | — |
| swift-http-structured-headers | 1.7.0 | [Apache 2.0](https://github.com/apple/swift-http-structured-headers/blob/933538faa42c432d385f02e07df0ace7c5ecfc47/LICENSE.txt) | — |
| swift-http-types | 1.7.0 | [Apache 2.0](https://github.com/apple/swift-http-types/blob/6c8ca8297332ea2780c45e1bce9d7fd2a8b51e1d/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-http-types/blob/6c8ca8297332ea2780c45e1bce9d7fd2a8b51e1d/NOTICE.txt) |
| swift-log | 1.15.0 | [Apache 2.0](https://github.com/apple/swift-log/blob/3ffafb9722d5d918c614feb496c8789a3b59d222/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-log/blob/3ffafb9722d5d918c614feb496c8789a3b59d222/NOTICE.txt) |
| swift-metrics | 2.11.0 | [Apache 2.0](https://github.com/apple/swift-metrics/blob/087e8074afa97040c3b870c8664fe5482fb87cc4/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-metrics/blob/087e8074afa97040c3b870c8664fe5482fb87cc4/NOTICE.txt) |
| swift-nio | 2.102.0 | [Apache 2.0](https://github.com/apple/swift-nio/blob/a931f2c1de8dd49381ce3bf2e279d033f68d8865/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-nio/blob/a931f2c1de8dd49381ce3bf2e279d033f68d8865/NOTICE.txt) |
| swift-nio-extras | 1.35.1 | [Apache 2.0](https://github.com/apple/swift-nio-extras/blob/41449336c8ecfadac6b4b5be75f9c3c306e61ced/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-nio-extras/blob/41449336c8ecfadac6b4b5be75f9c3c306e61ced/NOTICE.txt) |
| swift-nio-http2 | 1.46.0 | [Apache 2.0](https://github.com/apple/swift-nio-http2/blob/0f3e54e29c944c2e835ad52159da7d9e1c94ac69/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-nio-http2/blob/0f3e54e29c944c2e835ad52159da7d9e1c94ac69/NOTICE.txt) |
| swift-nio-ssl | 2.37.4 | [Apache 2.0](https://github.com/apple/swift-nio-ssl/blob/03827c1a9fdb2b6b00a4e93ede8861520263af8c/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-nio-ssl/blob/03827c1a9fdb2b6b00a4e93ede8861520263af8c/NOTICE.txt) |
| swift-nio-transport-services | 1.28.0 | [Apache 2.0](https://github.com/apple/swift-nio-transport-services/blob/67787bb645a5e67d2edcdfbe48a216cc549222d5/LICENSE.txt) | — |
| swift-numerics | 1.1.1 | [Apache 2.0 + Swift exception](https://github.com/apple/swift-numerics/blob/0c0290ff6b24942dadb83a929ffaaa1481df04a2/LICENSE.txt) | — |
| swift-service-context | 1.3.0 | [Apache 2.0](https://github.com/apple/swift-service-context/blob/d0997351b0c7779017f88e7a93bc30a1878d7f29/LICENSE.txt) | [NOTICE](https://github.com/apple/swift-service-context/blob/d0997351b0c7779017f88e7a93bc30a1878d7f29/NOTICE.txt) |
| swift-service-lifecycle | 2.12.0 | [Apache 2.0](https://github.com/swift-server/swift-service-lifecycle/blob/7f9326b0326ff86e3646295ea6e891f68c471c5e/LICENSE.txt) | [NOTICE](https://github.com/swift-server/swift-service-lifecycle/blob/7f9326b0326ff86e3646295ea6e891f68c471c5e/NOTICE.txt) |
| swift-system | 1.8.1 | [Apache 2.0 + Swift exception](https://github.com/apple/swift-system/blob/869129b7bf4ecc57b97d0193ad29690ca2134750/LICENSE.txt) | — |

The Swift exception is the upstream Runtime Library Exception to Apache 2.0;
retain its full text with the associated license. Package-level licenses do not
replace licenses for incorporated components. In particular, Hummingbird's
notice identifies Swift Foundation-derived code, SwiftNIO's notices identify
llhttp and other components, and SwiftNIO SSL's notice identifies BoringSSL.

When distributing a compiled application, include the complete matching
upstream `LICENSE` and `NOTICE` files and applicable incorporated-component
notices with the distribution. Those files are available in the resolved
`.build/checkouts` sources; the links above preserve their revision context.
This index does not replace their full text.

## Optional native workers

The [Workers package](Workers/README.md) links Midnight's shared runtime
libraries and pins the same MLX revisions. Its MLX, MLX-C, MLX Swift, MLX Swift
LM, MLX Audio Swift, Hugging Face, tokenizer, and argument-parser dependencies
retain their own terms. See the sibling
[Midnight third-party notices](../midnight/THIRD_PARTY_NOTICES.md) for the shared
runtime notices and MIT license text, and preserve the matching upstream files
from `Workers/.build/checkouts` when distributing worker binaries or Metal
libraries.

The separate quantization and research-training projects maintain their own
source and dependency notices. Downloaded checkpoints and imported training datasets retain the licenses
supplied by their owners.
