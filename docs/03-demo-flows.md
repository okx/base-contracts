# Demo Flow Diagrams

## Demo 1: Image Generation (No Hook)

A client requests an AI-generated image. No hook is used — the core handles all USDC escrow and payment natively.

```mermaid
sequenceDiagram
    participant C as Client
    participant Core as AgenticCommerce
    participant P as Provider
    participant E as Evaluator

    Note over C,E: -- Job Creation --
    C->>Core: createJob(provider, evaluator, expiry,<br/>"Generate landscape wallpaper", address(0), 0)
    Note over Core: Status: Open (no hook)

    Note over C,E: -- Budget --
    P->>Core: setBudget(jobId, USDC, 20 USDC, "0x")

    Note over C,E: -- Funding --
    rect rgb(255, 243, 224)
        C->>Core: fund(jobId, 20 USDC, "0x")
        Note over C,Core: 20 USDC: Client -> Core (escrowed)<br/>Open -> Funded
    end

    Note over C,E: -- Submit --
    P->>Core: submit(jobId, keccak256(imageURL), "0x")
    Note over Core: Funded -> Submitted

    Note over C,E: -- Complete --
    rect rgb(232, 245, 233)
        E->>Core: complete(jobId, "approved", "0x")
        Note over Core,P: 20 USDC -> Provider<br/>Submitted -> Completed
    end

    Note over C,E: -- Final State --
    Note over C: Balance: 0 USDC
    Note over P: Balance: +20 USDC
```

No hook involved. Pure core escrow flow.

## Demo 2: Dataset Evaluation with Partial Settlement (No Hook)

A client asks an AI provider to review and label a dataset in two milestones. The client escrows 100 USDC, authorizes a 40 USDC settlement after the first accepted batch, and final completion releases only the unsettled remainder.

```mermaid
sequenceDiagram
    participant C as Client
    participant Core as AgenticCommerce
    participant P as Provider
    participant E as Evaluator

    Note over C,E: -- Job Creation and Funding --
    C->>Core: createJob(provider, evaluator, expiry,<br/>"Review and label 10k support tickets", address(0), 0)
    P->>Core: setBudget(jobId, USDC, 100 USDC, "0x")
    C->>Core: fund(jobId, 100 USDC, "0x")
    Note over Core: Status: Funded<br/>settledAmount = 0

    Note over C,P: -- Milestone 1 --
    P-->>C: delivers batch-1 labels and confidence report
    C-->>P: signs Voucher(jobId, 40 USDC, "batch-1")
    P->>Core: settle(jobId, 40 USDC, voucherSig, "batch-1")
    Note over Core,P: 40 USDC delta paid to provider after fees<br/>settledAmount = 40 USDC

    Note over C,E: -- Final Submission and Evaluation --
    P->>Core: submit(jobId, keccak256(finalReportCID), "0x")
    E->>Core: complete(jobId, "approved", "0x")
    Note over Core,P: Remaining 60 USDC released after fees<br/>Submitted -> Completed
```
