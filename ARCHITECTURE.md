# Dapr EKS Pub/Sub Architecture
**Author**: Deepak  
**Project**: Containerized Microservices on Amazon EKS with Dapr Sidecars

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Amazon EKS Cluster                       │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    Namespace: dapr-apps                     │ │
│  │                                                             │ │
│  │  ┌─────────────────┐              ┌─────────────────┐      │ │
│  │  │  ProductService │              │  OrderService   │      │ │
│  │  │     Pod         │              │     Pod         │      │ │
│  │  │ ┌─────────────┐ │              │ ┌─────────────┐ │      │ │
│  │  │ │    App      │ │              │ │    App      │ │      │ │
│  │  │ │ Container   │ │              │ │ Container   │ │      │ │
│  │  │ │ Port: 8080  │ │              │ │ Port: 8090  │ │      │ │
│  │  │ └─────────────┘ │              │ └─────────────┘ │      │ │
│  │  │ ┌─────────────┐ │              │ ┌─────────────┐ │      │ │
│  │  │ │    Dapr     │ │              │ │    Dapr     │ │      │ │
│  │  │ │  Sidecar    │ │              │ │  Sidecar    │ │      │ │
│  │  │ │ Port: 3500  │ │              │ │ Port: 3500  │ │      │ │
│  │  │ └─────────────┘ │              │ └─────────────┘ │      │ │
│  │  └─────────────────┘              └─────────────────┘      │ │
│  │           │                                 ▲               │ │
│  │           │ HTTP POST                       │ Subscribe     │ │
│  │           │ /publish                        │               │ │
│  │           ▼                                 │               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │              Dapr SNS/SQS Component                     │ │ │
│  │  │                 (snssqs-pubsub)                         │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         AWS Services                            │
│                                                                 │
│  ┌─────────────┐    Fanout    ┌─────────────┐                  │
│  │ Amazon SNS  │ ──────────► │ Amazon SQS  │                  │
│  │   Topic:    │              │   Queue:    │                  │
│  │   orders    │              │   orders    │                  │
│  └─────────────┘              └─────────────┘                  │
│         ▲                             │                        │
│         │ Publish                     │ Poll/Receive           │
│         │                             ▼                        │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    ECR Repositories                         │ │
│  │  • productservice:latest                                    │ │
│  │  • orderservice:latest                                      │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘

Message Flow: ProductService → Dapr → SNS → SQS → Dapr → OrderService
```

## Component Details

### EKS Cluster:
- **Nodes**: 2x t3.medium EC2 instances
- **Namespace**: dapr-apps (application pods)
- **Namespace**: dapr-system (Dapr control plane)

### Application Pods:
- **ProductService**: Publisher microservice (Node.js)
- **OrderService**: Subscriber microservice (Node.js)
- **Dapr Sidecars**: Auto-injected, handle pub/sub communication

### AWS Integration:
- **ECR**: Container image registry
- **SNS**: Pub/sub topic management  
- **SQS**: Message queuing and delivery
- **IAM**: Service account permissions

### Message Flow:
1. HTTP POST → ProductService:8080/publish
2. ProductService → Dapr Sidecar:3500
3. Dapr → SNS Topic (orders)
4. SNS → SQS Queue (fanout)
5. SQS → Dapr Sidecar (poll)
6. Dapr → OrderService:8090/orders