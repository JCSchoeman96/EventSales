# EventSales D1 R3.4-D0: PgBouncer health-enabled image design authority

Status: DESIGN_DRAFTED. Human review and approval remain pending.

Base commit: `d96089d71a9cd7f2f4f8cd46d36b626ee390d6e0`.
Base tree: `d682e2726434b2ac5fa1de09ab3c5696ab0baf36`.

This document records the accepted HC1A, HC1B, and HC1C evidence and defines the proposed production image contract. It authorizes no implementation, publication, deployment, or R4.1 resumption.

Once approved, this amendment supersedes only:

1. The D1 PgBouncer final production-image identity in Section 7 of [the architecture design](2026-10-20-d1-vps-production-architecture-design.md).
2. R4.1's requirement in [the implementation plan](../plans/2026-10-20-d1-vps-production-implementation.md) that PgBouncer directly use the raw DHI digest.

Every other D1 architecture decision remains unchanged. The existing canonical design and implementation plan are unchanged by this draft. Approval selects the derived-image design; it does not supply a deployable digest or permit R4.1 to continue before the gates in Section 15.

## 1. Problem statement and accepted evidence

HC1A established that the exact frozen PgBouncer DHI contains no usable endpoint-health executable.

HC1B established that a `pg_isready` derivative works, but requires libpq plus the Kerberos/LDAP/SASL runtime dependency closure. Its fallback feasibility is accepted; it is not the selected final runtime.

HC1C established that a custom Rust std-only PostgreSQL-protocol probe succeeds against the exact frozen PgBouncer and requires zero runtime shared libraries. The spike produced a 459,520-byte static executable, passed 22 parser tests, and received `R`/10/`SCRAM-SHA-256` from real PgBouncer. The live listener-down check failed as required. No backend PostgreSQL was started. The spike source and temporary derived image were removed as required. Permanent reviewed source must be written from scratch.

The existing R4.1 requirement that healthchecks use commands available in the pinned image cannot be satisfied by the raw PgBouncer DHI. The selected solution supplies one endpoint-health executable in an immutable derived image, without runtime package installation.

## 2. Selected architecture

```text
FINAL_PGBOUNCER_IMAGE=EventSales-owned immutable derived image
BASE_IMAGE=dhi.io/pgbouncer:1.26.1-debian13@sha256:78fe21ad5b7c1ab497e9828eea9b951f9d6a58eb638946ddc61ef1f99737f1b1
BUILDER_IMAGE=rust:1-alpine3.24@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9
TARGET=linux/amd64
REGISTRY=ghcr.io/jcschoeman96/eventsales-pgbouncer
```

The DHI digest is the immutable base input, not the final production-image identity. Deployment authority is the independently verified published derived-image digest only. Never deploy from a mutable tag. R3.4 publication must establish that digest; this draft does not invent one.

## 3. Runtime delta invariant

The final image may add exactly one executable:

```text
/usr/local/bin/eventsales-pgbouncer-healthcheck
```

It must add none of the following:

```text
shared libraries: NONE
shell:            NONE
package manager:  NONE
curl/wget:        NONE
nc/socat:         NONE
runtime compiler: NONE
source code:      NONE
```

It must preserve:

```text
USER=65532
ENTRYPOINT=["pgbouncer"]
CMD=["/etc/pgbouncer/pgbouncer.ini"]
```

No base-image files may be replaced or removed.

## 4. Probe protocol contract

The executable remains generic. Its interface is:

```text
eventsales-pgbouncer-healthcheck <host> <port> <username>
```

Production R4.1 invocation will be:

```text
eventsales-pgbouncer-healthcheck 127.0.0.1 6432 eventsales_runtime
```

The username is not secret. Do not hardcode `event_sales_prod`, `application_name`, a password, a SCRAM verifier, or any production credential.

The probe sends exactly one PostgreSQL protocol 3.0 StartupMessage. Its only parameter is `user`, whose value comes from the username argument. At production invocation, that parameter is `user=eventsales_runtime`. It sends no database, application_name, or options parameter.

## 5. Probe state machine

```text
START
  -> CONNECT

CONNECT
  guard:
    TCP connection succeeds within bounded timeout
  fail:
    UNHEALTHY
  -> SEND_STARTUP

SEND_STARTUP
  side effect:
    send exactly one PostgreSQL v3 StartupMessage
  invariant:
    no password
    no SASL response
    no second StartupMessage
  -> READ_INITIAL_RESPONSE

READ_INITIAL_RESPONSE
  guard:
    valid bounded PostgreSQL frame
  accepted:
    type R
    authentication code 10
    SASL mechanism list contains SCRAM-SHA-256
    -> HEALTHY
  every other result:
    -> UNHEALTHY

HEALTHY
  terminal
  close connection
  exit 0

UNHEALTHY
  terminal
  close connection if opened
  exit non-zero
```

Connection and I/O waits must be bounded. The frame length limit is 4096 bytes. `ErrorResponse` is always unhealthy. There is no password/authentication transition and no backend connection transition. No SQL or backend PostgreSQL connection is part of health evaluation.

## 6. Production identity decision

Do not create a dedicated PgBouncer health user. Use the already-required client-facing PgBouncer identity `eventsales_runtime`.

The production probe uses `eventsales_runtime` because it is the already-required production-shaped client username and therefore adds no health-only identity or credential lifecycle. The probe needs no password.

The pre-authentication challenge does not prove that this username exists in `auth_file`. PgBouncer may deliberately perform mock authentication for unknown users to avoid user enumeration.

Existence and successful authentication of `eventsales_runtime` are proved later by R4.4, not by the container healthcheck.

The distinct `eventsales_runtime_client_password` and `eventsales_runtime_server_password` contract remains unchanged. The probe uses neither password.

## 7. Health semantic boundary

The container healthcheck proves only that PgBouncer:

- listens on its configured PostgreSQL endpoint;
- parses a valid PostgreSQL v3 StartupMessage;
- reaches its configured SCRAM client-authentication path; and
- advertises SCRAM-SHA-256.

It does not prove:

- existence of the supplied username in `auth_file`;
- correctness/completeness of `pgbouncer_users.txt`;
- password correctness;
- successful authentication;
- backend PostgreSQL availability;
- database existence;
- pool acquisition;
- transaction pooling correctness;
- prepared statements;
- backend role identity; or
- SQL execution.

These remain R4.4/integration proof responsibilities. R4.4 must prove that `eventsales_runtime` exists as a valid PgBouncer client identity, client SCRAM authentication succeeds, the client password is correct, the backend identity is `eventsales_runtime`, transaction pooling works, and prepared statements work. No authentication responsibility moves into the container healthcheck.

The accepted signal is the pre-authentication `AuthenticationSASL` challenge. Authentication rejection is not a required signal.

## 8. PgBouncer network contract

```text
PgBouncer listen_addr = 0.0.0.0
PgBouncer listen_port = 6432
health probe target = 127.0.0.1:6432
```

Do not bind PgBouncer itself only to loopback. EventSales must remain able to reach PgBouncer over the internal Docker data network. The listener address does not authorize a host port.

## 9. Source design for later implementation

Proposed permanent paths are:

```text
deploy/vps/data-plane/pgbouncer-image/
├── Dockerfile
└── eventsales_pgbouncer_healthcheck.rs
```

Keep parser/unit tests in the Rust source under `#[cfg(test)]` unless implementation evidence establishes a strong reason for a separate test file. Add no Cargo dependencies. Prefer direct `rustc` compilation because `EXTERNAL_CRATES=0` and `SOURCE_FILES=1`. Avoid Cargo project scaffolding unless compilation/test evidence requires it.

These paths are design decisions only. This amendment creates no Rust source or Dockerfile.

## 10. Builder contract

Build only with the exact Rust builder digest in Section 2. The builder is not part of the final runtime.

```text
target = x86_64-unknown-linux-musl
ELF interpreter = NONE
DT_NEEDED entries = NONE
maximum stripped binary size = 2 MiB
```

The build must fail if either static-link invariant fails or the stripped binary exceeds 2 MiB. Do not use UPX or another executable packer. Leave the existing build cache alone; no prune operation is justified.

## 11. Permanent test contract

R3.4 tests must cover at least:

| Input or condition | Required result |
| --- | --- |
| Valid R/10/SCRAM-SHA-256 | PASS |
| Connection refused | FAIL |
| Timeout | FAIL |
| Empty EOF | FAIL |
| Non-PostgreSQL bytes | FAIL |
| Truncated header | FAIL |
| Invalid short length | FAIL |
| Length > 4096 | FAIL |
| Truncated body | FAIL |
| Authentication code 0 | FAIL |
| Authentication code 3 | FAIL |
| Authentication code 5 | FAIL |
| Authentication code 10 without SCRAM-SHA-256 | FAIL |
| ErrorResponse | FAIL |
| Malformed ErrorResponse | FAIL |
| NegotiateProtocolVersion | FAIL |
| Unknown message type | FAIL |

Also verify that the StartupMessage contains user, omits database, application_name, and options, and is sent exactly once. No password message or SASL response may be sent.

## 12. Integration test contract

Against the exact final derived image and a temporary synthetic PgBouncer configuration, prove:

```text
KNOWN_AUTH_FILE_USER=R/10/SCRAM-SHA-256 -> exit 0
LISTENER_DOWN=exit non-zero
NON_POSTGRES_LISTENER=exit non-zero
```

No backend PostgreSQL may be started for these tests. Use synthetic fixture identities and credentials only.

An optional unknown-user test may record diagnostic evidence only, with no required PASS/FAIL semantic. The unknown-user result is not a health invariant and must not be used to infer username existence or non-existence. Do not change the probe implementation based on the unknown-user result.

## 13. Final image hardening

Preserve the existing PgBouncer production envelope:

```text
UID/GID 65532:65532
read-only root filesystem
0.5 CPU
128 MiB
all capabilities dropped
no-new-privileges
internal data network only
no host port
SCRAM
transaction pool
```

The derived image does not alter these R4.1 Compose controls. All other pool settings and D1 architecture decisions remain unchanged.

## 14. Publication contract for later implementation

R3.4 later creates a dedicated workflow at:

```text
.github/workflows/event-sales-pgbouncer-image.yml
```

Do not overload or change the existing application-image workflow. Follow its accepted publication model:

```text
triggers = push main + manual dispatch
publish from PR = never
permissions = contents: read; packages: write
platform = linux/amd64
immutable tag = full commit SHA
latest tag = prohibited
human tag = optional, guarded
BuildKit provenance = mode=max
SBOM = enabled
OCI labels = source and revision
digest metadata artifact = required
deployment = none
registry = ghcr.io/jcschoeman96/eventsales-pgbouncer
```

Publishing an image does not authorize deployment. This docs-only gate creates or modifies no workflow.

## 15. R4.1 authority transition

R4.1 remains blocked until all of the following occur:

1. The R3.4 design is approved.
2. The R3.4 implementation plan is approved.
3. The R3.4 implementation is reviewed and accepted.
4. R3.4 is merged.
5. The R3.4 publication workflow succeeds on accepted main.
6. The published digest is independently verified.
7. The derived image runtime invariants are independently verified.

Only then may the exact derived digest replace the raw PgBouncer digest in R4.1, subject to explicit R4.1 resume authorization. PostgreSQL and Redis image authorities remain unchanged. No failed gate may silently advance to R4.1.

## 16. Lifecycle and authorization

```text
HC1C_FEASIBILITY_ACCEPTED
  -> DESIGN_DRAFTED
  -> DESIGN_APPROVED
  -> IMPLEMENTATION_PLANNED
  -> IMPLEMENTATION_AUTHORIZED
  -> IMPLEMENTED
  -> REVIEW_ACCEPTED
  -> MERGED
  -> IMAGE_PUBLISHED
  -> DIGEST_VERIFIED
  -> R4_1_RESUME_AUTHORIZED
```

Failure/terminal states are:

```text
DESIGN_REJECTED
IMPLEMENTATION_BLOCKED
REVIEW_REJECTED
PUBLICATION_BLOCKED
DIGEST_REJECTED
```

A failed state cannot advance to R4.1. Review and explicit authorization must resolve the relevant gate first.

At this docs-only gate:

```text
HC1A=ACCEPTED
HC1B=ACCEPTED_FALLBACK_FEASIBILITY
HC1C=ACCEPTED_SELECTED_FEASIBILITY
R3_4_D0_DESIGN_AUTHORING=AUTHORIZED
R3_4_DESIGN_ACCEPTED=NO
R3_4_IMPLEMENTATION_PLAN_AUTHORIZED=NO
R3_4_IMPLEMENTATION_AUTHORIZED=NO
R4_1_RESUME_AUTHORIZED=NO
R4_2_AUTHORIZED=NO
VPS_MUTATION_AUTHORIZED=NO
```

Do not write the implementation plan or begin Rust, Dockerfile, or workflow implementation at this gate.

## 17. Rejected alternatives

| Alternative | Reason for rejection |
| --- | --- |
| Raw PgBouncer DHI as final runtime | No endpoint-health capability. It remains the selected immutable base. |
| pg_isready derivative | Technically feasible, but adds libpq plus the Kerberos/LDAP/SASL dependency closure. |
| TCP-only custom probe | Too weak; does not prove the required PostgreSQL protocol response. |
| Dedicated healthcheck user | Adds an unnecessary identity and credential lifecycle. |
| Sidecar | Breaks the frozen three-service topology. |
| Broader PgBouncer image | Adds unnecessary runtime attack surface. |
| No PgBouncer healthcheck | Weakens the production contract. |
