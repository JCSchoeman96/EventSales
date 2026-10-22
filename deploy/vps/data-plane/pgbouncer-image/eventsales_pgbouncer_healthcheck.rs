use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::time::{Duration, Instant};

const MAX_FRAME_LENGTH: u32 = 4_096;
const IO_DEADLINE: Duration = Duration::from_secs(2);

#[derive(Debug, PartialEq, Eq)]
enum ProbeError {
    Usage,
    InvalidResponse,
    Io,
}

#[derive(Debug, PartialEq, Eq)]
struct ProbeArgs {
    host: IpAddr,
    port: u16,
    username: String,
}

fn parse_host(host: &str) -> Result<IpAddr, ProbeError> {
    host.parse().map_err(|_| ProbeError::Usage)
}

fn parse_args(args: &[String]) -> Result<ProbeArgs, ProbeError> {
    if args.len() != 4 {
        return Err(ProbeError::Usage);
    }

    let host = parse_host(&args[1])?;
    let port = args[2].parse::<u16>().map_err(|_| ProbeError::Usage)?;
    let username = &args[3];
    if port == 0 || username.is_empty() || username.as_bytes().contains(&0) {
        return Err(ProbeError::Usage);
    }

    Ok(ProbeArgs {
        host,
        port,
        username: username.clone(),
    })
}

fn startup_message(username: &str) -> Result<Vec<u8>, ProbeError> {
    if username.is_empty() || username.as_bytes().contains(&0) {
        return Err(ProbeError::Usage);
    }

    let message_length = 15_usize
        .checked_add(username.len())
        .ok_or(ProbeError::Usage)?;
    let message_length_u32 = u32::try_from(message_length).map_err(|_| ProbeError::Usage)?;
    let mut message = Vec::new();
    message
        .try_reserve_exact(message_length)
        .map_err(|_| ProbeError::Usage)?;
    message.extend_from_slice(&message_length_u32.to_be_bytes());
    message.extend_from_slice(&196_608_u32.to_be_bytes());
    message.extend_from_slice(b"user\0");
    message.extend_from_slice(username.as_bytes());
    message.extend_from_slice(b"\0\0");
    Ok(message)
}

fn read_auth_response<R: Read>(reader: &mut R) -> Result<(), ProbeError> {
    let mut message_type = [0_u8; 1];
    reader
        .read_exact(&mut message_type)
        .map_err(|_| ProbeError::InvalidResponse)?;
    if message_type[0] != b'R' {
        return Err(ProbeError::InvalidResponse);
    }

    let mut length_bytes = [0_u8; 4];
    reader
        .read_exact(&mut length_bytes)
        .map_err(|_| ProbeError::InvalidResponse)?;
    let frame_length = u32::from_be_bytes(length_bytes);
    if !(4..=MAX_FRAME_LENGTH).contains(&frame_length) {
        return Err(ProbeError::InvalidResponse);
    }

    let body_length = (frame_length - 4) as usize;
    let mut body = [0_u8; (MAX_FRAME_LENGTH - 4) as usize];
    reader
        .read_exact(&mut body[..body_length])
        .map_err(|_| ProbeError::InvalidResponse)?;
    if body_length < 4 {
        return Err(ProbeError::InvalidResponse);
    }

    let mut authentication_code_bytes = [0_u8; 4];
    authentication_code_bytes.copy_from_slice(&body[..4]);
    let authentication_code = u32::from_be_bytes(authentication_code_bytes);
    if authentication_code != 10 || !has_exact_scram_mechanism(&body[4..body_length]) {
        return Err(ProbeError::InvalidResponse);
    }

    Ok(())
}

fn has_exact_scram_mechanism(mechanisms: &[u8]) -> bool {
    let mut offset = 0;
    let mut found_scram = false;

    loop {
        let remaining = &mechanisms[offset..];
        let Some(name_length) = remaining.iter().position(|byte| *byte == 0) else {
            return false;
        };
        let name = &remaining[..name_length];
        offset += name_length + 1;

        if name.is_empty() {
            return found_scram && offset == mechanisms.len();
        }
        if name == b"SCRAM-SHA-256" {
            found_scram = true;
        }
    }
}

fn healthcheck(args: &ProbeArgs) -> Result<(), ProbeError> {
    let startup = startup_message(&args.username)?;
    let deadline = Instant::now() + IO_DEADLINE;
    let timeout = remaining_time(deadline)?;
    let address = SocketAddr::new(args.host, args.port);
    let mut stream = TcpStream::connect_timeout(&address, timeout).map_err(|_| ProbeError::Io)?;
    remaining_time(deadline)?;
    write_startup_until(&mut stream, &startup, deadline)?;
    let mut reader = DeadlineReader {
        stream: &mut stream,
        deadline,
    };
    read_auth_response(&mut reader)
}

fn remaining_time(deadline: Instant) -> Result<Duration, ProbeError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(ProbeError::Io)
    } else {
        Ok(remaining)
    }
}

fn write_startup_until(
    stream: &mut TcpStream,
    startup: &[u8],
    deadline: Instant,
) -> Result<(), ProbeError> {
    let mut offset = 0;
    while offset < startup.len() {
        stream
            .set_write_timeout(Some(remaining_time(deadline)?))
            .map_err(|_| ProbeError::Io)?;
        match stream.write(&startup[offset..]) {
            Ok(0) => return Err(ProbeError::Io),
            Ok(bytes_written) => {
                offset += bytes_written;
                remaining_time(deadline)?;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return Err(ProbeError::Io),
        }
    }
    Ok(())
}

struct DeadlineReader<'a> {
    stream: &'a mut TcpStream,
    deadline: Instant,
}

impl Read for DeadlineReader<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "I/O deadline expired"))?;
        self.stream.set_read_timeout(Some(remaining))?;
        let bytes_read = self.stream.read(buffer)?;
        if Instant::now() >= self.deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "I/O deadline expired",
            ));
        }
        Ok(bytes_read)
    }
}

fn run(args: &[String]) -> Result<(), ProbeError> {
    let args = parse_args(args)?;
    healthcheck(&args)
}

fn main() -> std::process::ExitCode {
    let args = std::env::args_os()
        .map(|argument| argument.into_string())
        .collect::<Result<Vec<_>, _>>();
    let Ok(args) = args else {
        eprintln!("UNHEALTHY");
        return std::process::ExitCode::FAILURE;
    };

    match run(&args) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(_) => {
            eprintln!("UNHEALTHY");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        healthcheck, parse_args, parse_host, read_auth_response, startup_message, ProbeArgs,
        ProbeError,
    };
    use std::io::{self, Cursor, Read, Write};
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
    use std::process::{Command, Stdio};
    use std::thread;
    use std::time::{Duration, Instant};

    fn string_args(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_owned()).collect()
    }

    fn raw_frame(message_type: u8, body: &[u8]) -> Vec<u8> {
        let length = 4 + body.len();
        let mut frame = Vec::with_capacity(length + 1);
        frame.push(message_type);
        frame.extend_from_slice(&(length as u32).to_be_bytes());
        frame.extend_from_slice(body);
        frame
    }

    fn auth_frame(code: u32, mechanisms: &[u8]) -> Vec<u8> {
        let mut body = code.to_be_bytes().to_vec();
        body.extend_from_slice(mechanisms);
        raw_frame(b'R', &body)
    }

    fn assert_healthy(frame: &[u8]) {
        assert!(read_auth_response(&mut Cursor::new(frame)).is_ok());
    }

    fn assert_unhealthy(frame: &[u8]) {
        assert!(read_auth_response(&mut Cursor::new(frame)).is_err());
    }

    #[test]
    fn startup_message_has_one_postgres_v3_user_parameter() {
        let username = "r3_4_probe_user";
        let message = startup_message(username).expect("valid username should serialize");
        let mut expected = Vec::new();
        let length = 15 + username.len();
        expected.extend_from_slice(&(length as u32).to_be_bytes());
        expected.extend_from_slice(&196_608_u32.to_be_bytes());
        expected.extend_from_slice(b"user\0");
        expected.extend_from_slice(username.as_bytes());
        expected.extend_from_slice(b"\0\0");

        assert_eq!(message, expected);
        assert_eq!(u32::from_be_bytes(message[0..4].try_into().unwrap()) as usize, message.len());
        assert_eq!(u32::from_be_bytes(message[4..8].try_into().unwrap()), 196_608);
        assert!(!message.windows(b"database\0".len()).any(|part| part == b"database\0"));
        assert!(!message
            .windows(b"application_name\0".len())
            .any(|part| part == b"application_name\0"));
        assert!(!message.windows(b"options\0".len()).any(|part| part == b"options\0"));
    }

    #[test]
    fn startup_message_rejects_embedded_nul_username() {
        assert_eq!(startup_message("probe\0user"), Err(ProbeError::Usage));
    }

    #[test]
    fn cli_accepts_numeric_ipv4_and_ipv6_hosts() {
        assert_eq!(parse_host("127.0.0.1"), Ok(IpAddr::V4(Ipv4Addr::LOCALHOST)));
        assert_eq!(parse_host("::1"), Ok(IpAddr::V6(Ipv6Addr::LOCALHOST)));
    }

    #[test]
    fn cli_rejects_hostname_before_dns_or_socket_activity() {
        assert_eq!(parse_host("example.invalid"), Err(ProbeError::Usage));
        let args = string_args(&["probe", "example.invalid", "6432", "probe_user"]);
        assert_eq!(parse_args(&args), Err(ProbeError::Usage));
    }

    #[test]
    fn cli_accepts_exact_arguments_and_valid_port() {
        let args = string_args(&["probe", "127.0.0.1", "6432", "r3_4_probe_user"]);
        assert_eq!(
            parse_args(&args),
            Ok(ProbeArgs {
                host: IpAddr::V4(Ipv4Addr::LOCALHOST),
                port: 6432,
                username: "r3_4_probe_user".to_owned(),
            })
        );
    }

    #[test]
    fn cli_rejects_missing_arguments() {
        let args = string_args(&["probe", "127.0.0.1", "6432"]);
        assert_eq!(parse_args(&args), Err(ProbeError::Usage));
    }

    #[test]
    fn cli_rejects_extra_arguments() {
        let args = string_args(&["probe", "127.0.0.1", "6432", "probe_user", "extra"]);
        assert_eq!(parse_args(&args), Err(ProbeError::Usage));
    }

    #[test]
    fn cli_rejects_invalid_and_zero_ports() {
        let invalid = string_args(&["probe", "127.0.0.1", "not-a-port", "probe_user"]);
        let zero = string_args(&["probe", "127.0.0.1", "0", "probe_user"]);
        assert_eq!(parse_args(&invalid), Err(ProbeError::Usage));
        assert_eq!(parse_args(&zero), Err(ProbeError::Usage));
    }

    #[test]
    fn cli_rejects_embedded_nul_username() {
        let args = string_args(&["probe", "127.0.0.1", "6432", "probe\0user"]);
        assert_eq!(parse_args(&args), Err(ProbeError::Usage));
    }

    #[test]
    fn parser_accepts_exact_authentication_sasl_challenge() {
        assert_healthy(&auth_frame(10, b"SCRAM-SHA-256\0\0"));
    }

    #[test]
    fn parser_rejects_empty_eof_and_non_postgresql_bytes() {
        assert_unhealthy(&[]);
        assert_unhealthy(b"HTTP/1.1 200 OK\r\n");
    }

    #[test]
    fn parser_rejects_truncated_header_and_invalid_lengths() {
        assert_unhealthy(b"R\0\0");
        assert_unhealthy(b"R\0\0\0\x03");
        assert_unhealthy(b"R\0\0\x10\x01");
    }

    #[test]
    fn parser_rejects_u32_max_from_header_without_reading_body() {
        struct HeaderOnly {
            header: [u8; 5],
            offset: usize,
            reads_after_header: usize,
        }

        impl Read for HeaderOnly {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                if self.offset == self.header.len() {
                    self.reads_after_header += 1;
                    return Ok(0);
                }
                let count = buffer.len().min(self.header.len() - self.offset);
                buffer[..count]
                    .copy_from_slice(&self.header[self.offset..self.offset + count]);
                self.offset += count;
                Ok(count)
            }
        }

        let mut reader = HeaderOnly {
            header: [b'R', 0xff, 0xff, 0xff, 0xff],
            offset: 0,
            reads_after_header: 0,
        };
        assert!(read_auth_response(&mut reader).is_err());
        assert_eq!(reader.reads_after_header, 0);
    }

    #[test]
    fn parser_rejects_truncated_body() {
        let mut frame = vec![b'R'];
        frame.extend_from_slice(&8_u32.to_be_bytes());
        frame.extend_from_slice(&[0, 0]);
        assert_unhealthy(&frame);
    }

    #[test]
    fn parser_rejects_authentication_codes_other_than_ten() {
        for code in [0, 3, 5] {
            assert_unhealthy(&auth_frame(code, b"SCRAM-SHA-256\0\0"));
        }
    }

    #[test]
    fn parser_rejects_code_ten_without_exact_scram_mechanism() {
        assert_unhealthy(&auth_frame(10, b"SCRAM-SHA-256-PLUS\0\0"));
    }

    #[test]
    fn parser_rejects_error_and_malformed_error_responses() {
        assert_unhealthy(&raw_frame(
            b'E',
            b"SERROR\0C28P01\0Msynthetic failure\0\0",
        ));
        assert_unhealthy(&[b'E', 0, 0, 0, 4]);
    }

    #[test]
    fn parser_rejects_negotiate_protocol_and_unknown_message_types() {
        assert_unhealthy(&raw_frame(b'v', &[0, 0, 0, 0, 0, 0]));
        assert_unhealthy(&raw_frame(b'?', &[0, 0, 0, 0]));
    }

    #[test]
    fn parser_rejects_missing_or_unterminated_sasl_list_entries() {
        assert_unhealthy(&auth_frame(10, b"SCRAM-SHA-256\0"));
        assert_unhealthy(&auth_frame(10, b"SCRAM-SHA-256"));
        assert_unhealthy(&auth_frame(10, b"\0"));
    }

    #[test]
    fn parser_rejects_scram_prefix_suffix_lookalikes_and_trailing_junk() {
        assert_unhealthy(&auth_frame(10, b"X-SCRAM-SHA-256\0\0"));
        assert_unhealthy(&auth_frame(10, b"SCRAM-SHA-256-X\0\0"));
        assert_unhealthy(&auth_frame(10, b"SCRAM-SHA-256\0\0junk"));
    }

    #[test]
    fn parser_accepts_list_with_other_mechanism_and_exact_scram() {
        assert_healthy(&auth_frame(
            10,
            b"SCRAM-SHA-256-PLUS\0SCRAM-SHA-256\0\0",
        ));
    }

    #[test]
    fn parser_accepts_bounded_frame_with_declared_length_4096() {
        let mut mechanisms = vec![b'A'; 4_072];
        mechanisms.push(0);
        mechanisms.extend_from_slice(b"SCRAM-SHA-256\0\0");
        let frame = auth_frame(10, &mechanisms);
        assert_eq!(u32::from_be_bytes(frame[1..5].try_into().unwrap()), 4_096);
        assert_healthy(&frame);
    }

    #[test]
    fn parser_handles_fragmented_raw_frame_reads() {
        struct ChunkedReader<'a> {
            inner: Cursor<&'a [u8]>,
            chunk_size: usize,
        }

        impl Read for ChunkedReader<'_> {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                let limit = buffer.len().min(self.chunk_size);
                self.inner.read(&mut buffer[..limit])
            }
        }

        let frame = auth_frame(10, b"SCRAM-SHA-256\0\0");
        let mut reader = ChunkedReader {
            inner: Cursor::new(&frame),
            chunk_size: 1,
        };
        assert!(read_auth_response(&mut reader).is_ok());
    }

    fn child_args(address: SocketAddr) -> ProbeArgs {
        ProbeArgs {
            host: address.ip(),
            port: address.port(),
            username: "probe_user".to_owned(),
        }
    }

    fn read_startup_packet(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
        let mut length_bytes = [0_u8; 4];
        stream.read_exact(&mut length_bytes)?;
        let length = u32::from_be_bytes(length_bytes) as usize;
        if !(8..=4_096).contains(&length) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid startup length"));
        }
        let mut packet = length_bytes.to_vec();
        packet.resize(length, 0);
        stream.read_exact(&mut packet[4..])?;
        Ok(packet)
    }

    fn accept_bounded(listener: &TcpListener) -> io::Result<TcpStream> {
        listener.set_nonblocking(true)?;
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match listener.accept() {
                Ok((stream, _)) => return Ok(stream),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err(io::Error::new(io::ErrorKind::TimedOut, "accept timed out"));
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => return Err(error),
            }
        }
    }

    fn auth_response(code: u32) -> Vec<u8> {
        auth_frame(code, b"SCRAM-SHA-256\0\0")
    }

    fn write_fragmented(stream: &mut TcpStream, bytes: &[u8], delay: Duration) {
        for byte in bytes {
            if stream.write_all(&[*byte]).is_err() {
                break;
            }
            if !delay.is_zero() {
                thread::sleep(delay);
            }
        }
    }

    fn run_network_child(scenario: &str) {
        if scenario == "refused" {
            let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
            let address = listener.local_addr().unwrap();
            drop(listener);
            assert!(matches!(
                healthcheck(&child_args(address)),
                Err(ProbeError::Io)
            ));
            return;
        }

        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let server_scenario = scenario.to_owned();
        let server = thread::spawn(move || {
            let mut stream = accept_bounded(&listener).expect("probe should connect to fixture");
            let startup = read_startup_packet(&mut stream).expect("one startup packet");
            match server_scenario.as_str() {
                "silent" => thread::sleep(Duration::from_millis(2_500)),
                "partial-header" => {
                    stream.write_all(b"R\0\0").unwrap();
                    stream.shutdown(Shutdown::Write).unwrap();
                }
                "partial-body" => {
                    stream.write_all(&[b'R', 0, 0, 0, 8, 0, 0]).unwrap();
                    stream.shutdown(Shutdown::Write).unwrap();
                }
                "fragmented-valid" => {
                    write_fragmented(&mut stream, &auth_response(10), Duration::from_millis(5));
                }
                "slow-peer" => {
                    write_fragmented(&mut stream, &auth_response(10), Duration::from_millis(350));
                }
                "rejected-frame" => {
                    stream.write_all(&auth_response(0)).unwrap();
                }
                _ => panic!("unknown network test scenario"),
            }
            let mut trailing = Vec::new();
            stream.read_to_end(&mut trailing).unwrap();
            (startup, trailing)
        });

        let started = Instant::now();
        let result = healthcheck(&child_args(address));
        let elapsed = started.elapsed();
        if scenario == "fragmented-valid" {
            assert_eq!(result, Ok(()));
        } else {
            assert!(matches!(
                result,
                Err(ProbeError::Io | ProbeError::InvalidResponse)
            ));
        }
        if scenario == "silent" || scenario == "slow-peer" {
            assert!(elapsed >= Duration::from_millis(1_750), "returned too early: {elapsed:?}");
            assert!(elapsed <= Duration::from_millis(2_800), "returned too late: {elapsed:?}");
        }

        let (startup, trailing) = server.join().expect("fixture thread should finish");
        assert_eq!(u32::from_be_bytes(startup[0..4].try_into().unwrap()) as usize, startup.len());
        assert_eq!(u32::from_be_bytes(startup[4..8].try_into().unwrap()), 196_608);
        assert_eq!(&startup[8..], b"user\0probe_user\0\0");
        assert!(trailing.is_empty(), "probe sent data after its one StartupMessage");
    }

    fn run_child_with_watchdog(scenario: &str) {
        let executable = std::env::current_exe().expect("test executable path");
        let mut child = Command::new(executable)
            .args(["--exact", "tests::network_child", "--nocapture"])
            .env("EVENTSALES_PROBE_NETWORK_SCENARIO", scenario)
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn test child");
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = child.try_wait().expect("check test child") {
                assert!(status.success(), "network scenario {scenario} failed");
                return;
            }
            if Instant::now() >= deadline {
                child.kill().expect("kill hung test child");
                let _ = child.wait();
                panic!("network scenario {scenario} exceeded five-second watchdog");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn network_child() {
        if let Ok(scenario) = std::env::var("EVENTSALES_PROBE_NETWORK_SCENARIO") {
            run_network_child(&scenario);
        }
    }

    #[test]
    fn networking_rejects_refused_connection() {
        run_child_with_watchdog("refused");
    }

    #[test]
    fn networking_fails_when_peer_is_silent() {
        run_child_with_watchdog("silent");
    }

    #[test]
    fn networking_fails_after_partial_header_eof() {
        run_child_with_watchdog("partial-header");
    }

    #[test]
    fn networking_fails_after_partial_body_eof() {
        run_child_with_watchdog("partial-body");
    }

    #[test]
    fn networking_accepts_fragmented_valid_response_and_sends_nothing_else() {
        run_child_with_watchdog("fragmented-valid");
    }

    #[test]
    fn networking_deadline_rejects_dripping_peer() {
        run_child_with_watchdog("slow-peer");
    }

    #[test]
    fn networking_closes_after_rejected_initial_response() {
        run_child_with_watchdog("rejected-frame");
    }
}
