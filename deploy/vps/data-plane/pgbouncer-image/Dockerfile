FROM rust:1-alpine3.24@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9 AS build

WORKDIR /src
COPY eventsales_pgbouncer_healthcheck.rs /src/eventsales_pgbouncer_healthcheck.rs

RUN --network=none rustc \
      --edition=2021 \
      --test \
      --target x86_64-unknown-linux-musl \
      /src/eventsales_pgbouncer_healthcheck.rs \
      -o /tmp/eventsales-pgbouncer-healthcheck-tests \
    && /tmp/eventsales-pgbouncer-healthcheck-tests \
    && rustc \
      --edition=2021 \
      --target x86_64-unknown-linux-musl \
      -C opt-level=3 \
      -C strip=symbols \
      /src/eventsales_pgbouncer_healthcheck.rs \
      -o /tmp/eventsales-pgbouncer-healthcheck

FROM rust:1-alpine3.24@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9 AS verify

COPY --from=build /tmp/eventsales-pgbouncer-healthcheck /out/eventsales-pgbouncer-healthcheck

RUN --network=none /bin/sh -eu -c '\
count_bytes() { \
  count_output=$(wc -c < "$1") || return 1; \
  set -- $count_output; \
  count=${1-}; \
  case "$count" in ""|*[!0-9]*) return 1 ;; esac; \
  printf "%s" "$count"; \
}; \
verify_elf() { \
  candidate=$1; \
  if [ ! -f "$candidate" ] || [ ! -x "$candidate" ]; then \
    printf "ELF verifier: missing or non-executable file: %s\n" "$candidate" >&2; \
    return 1; \
  fi; \
  size=$(count_bytes "$candidate") || { printf "ELF verifier: cannot measure %s\n" "$candidate" >&2; return 1; }; \
  if [ "$size" -gt 2097152 ]; then \
    printf "ELF verifier: file exceeds 2097152 bytes: %s (%s)\n" "$candidate" "$size" >&2; \
    return 1; \
  fi; \
  header=$(readelf -hW "$candidate") || { printf "ELF verifier: invalid ELF header: %s\n" "$candidate" >&2; return 1; }; \
  case "$header" in *"Machine:"*"Advanced Micro Devices X86-64"*) ;; *) printf "ELF verifier: architecture is not x86-64: %s\n" "$candidate" >&2; return 1 ;; esac; \
  program_headers=$(readelf -lW "$candidate") || { printf "ELF verifier: cannot read program headers: %s\n" "$candidate" >&2; return 1; }; \
  case "$program_headers" in *INTERP*) printf "ELF verifier: PT_INTERP is present: %s\n" "$candidate" >&2; return 1 ;; esac; \
  dynamic_section=$(readelf -dW "$candidate" 2>&1) || { printf "ELF verifier: cannot read dynamic section: %s\n" "$candidate" >&2; return 1; }; \
  case "$dynamic_section" in *NEEDED*) printf "ELF verifier: DT_NEEDED is present: %s\n" "$candidate" >&2; return 1 ;; esac; \
  printf "STATIC_ELF_PASS size=%s path=%s\n" "$size" "$candidate"; \
}; \
artifact=/out/eventsales-pgbouncer-healthcheck; \
verify_elf "$artifact"; \
dynamic=/usr/bin/readelf; \
dynamic_size=$(count_bytes "$dynamic") || { printf "ELF verifier: cannot measure dynamic fixture\n" >&2; exit 1; }; \
test -x "$dynamic"; \
test "$dynamic_size" -le 2097152; \
dynamic_header=$(readelf -hW "$dynamic"); \
case "$dynamic_header" in *"Machine:"*"Advanced Micro Devices X86-64"*) ;; *) printf "Dynamic fixture is not x86-64\n" >&2; exit 1 ;; esac; \
dynamic_program_headers=$(readelf -lW "$dynamic"); \
case "$dynamic_program_headers" in *INTERP*) ;; *) printf "Dynamic fixture lacks PT_INTERP\n" >&2; exit 1 ;; esac; \
dynamic_section=$(readelf -dW "$dynamic" 2>&1); \
case "$dynamic_section" in *NEEDED*) ;; *) printf "Dynamic fixture lacks DT_NEEDED\n" >&2; exit 1 ;; esac; \
if verify_elf "$dynamic"; then printf "ELF verifier accepted dynamic fixture\n" >&2; exit 1; fi; \
printf "DYNAMIC_FIXTURE_REJECTED=YES\n"; \
cp -p "$artifact" /tmp/oversize-elf; \
printf "%02100000d" 0 >> /tmp/oversize-elf; \
oversize_size=$(count_bytes /tmp/oversize-elf) || { printf "ELF verifier: cannot measure oversize fixture\n" >&2; exit 1; }; \
test "$oversize_size" -gt 2097152; \
test -x /tmp/oversize-elf; \
oversize_header=$(readelf -hW /tmp/oversize-elf); \
case "$oversize_header" in *"Machine:"*"Advanced Micro Devices X86-64"*) ;; *) printf "Oversize fixture is not x86-64\n" >&2; exit 1 ;; esac; \
oversize_program_headers=$(readelf -lW /tmp/oversize-elf); \
case "$oversize_program_headers" in *INTERP*) printf "Oversize fixture unexpectedly has PT_INTERP\n" >&2; exit 1 ;; esac; \
oversize_dynamic_section=$(readelf -dW /tmp/oversize-elf 2>&1); \
case "$oversize_dynamic_section" in *NEEDED*) printf "Oversize fixture unexpectedly has DT_NEEDED\n" >&2; exit 1 ;; esac; \
if verify_elf /tmp/oversize-elf; then printf "ELF verifier accepted oversize fixture\n" >&2; exit 1; fi; \
printf "OVERSIZE_FIXTURE_REJECTED=YES size=%s\n" "$oversize_size"'

FROM dhi.io/pgbouncer:1.26.1-debian13@sha256:78fe21ad5b7c1ab497e9828eea9b951f9d6a58eb638946ddc61ef1f99737f1b1 AS runtime

ARG SOURCE_URL
ARG VCS_REF

LABEL org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${VCS_REF}"

COPY --from=verify --chmod=0755 /out/eventsales-pgbouncer-healthcheck /usr/local/bin/eventsales-pgbouncer-healthcheck
