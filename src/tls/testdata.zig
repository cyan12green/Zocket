//! Test fixtures shared across the TLS module: an ECDSA P-256 certificate
//! and key pair (self-signed, generated with openssl) used by the unit and
//! integration tests.

pub const cert_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBgjCCASegAwIBAgIUJJXM/gwr5mqc1ciE50yHKkS/Fw0wCgYIKoZIzj0EAwIw
    \\FjEUMBIGA1UEAwwLem9ja2V0LXRlc3QwHhcNMjYwODE2MDQ0NTA0WhcNMzYwODEz
    \\MDQ0NTA0WjAWMRQwEgYDVQQDDAt6b2NrZXQtdGVzdDBZMBMGByqGSM49AgEGCCqG
    \\SM49AwEHA0IABGJx0GzFvloM4k/e+qhMfnR8R1fJdOyLlOCWZT61nouvYszZmOAS
    \\4WpTxVnip8mWoIqkwkCyzw6wdEOMsi+klxejUzBRMB0GA1UdDgQWBBSYhQcTp0GY
    \\6+4EE3N5x+fQPWmy6TAfBgNVHSMEGDAWgBSYhQcTp0GY6+4EE3N5x+fQPWmy6TAP
    \\BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDbwEssj3iI8328T+Rz
    \\cvFtssbDb4kbI2VrKhUcEf+SrQIhAMHLq2MogzpNGWCIKwVp+PGYfS5uT2gOJ1qx
    \\0HyJrl0O
    \\-----END CERTIFICATE-----
;

pub const key_pem =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEIMLJ2ZkEQS31wRzzM7wCwPQEe+Z8Nc1OtBfg40rywd0DoAoGCCqGSM49
    \\AwEHoUQDQgAEYnHQbMW+WgziT976qEx+dHxHV8l07IuU4JZlPrWei69izNmY4BLh
    \\alPFWeKnyZagiqTCQLLPDrB0Q4yyL6SXFw==
    \\-----END EC PRIVATE KEY-----
;

pub const key_pkcs8_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgwsnZmQRBLfXBHPMz
    \\vALA9AR75nw1zU60F+DjSvLB3QOhRANCAARicdBsxb5aDOJP3vqoTH50fEdXyXTs
    \\i5TglmU+tZ6Lr2LM2ZjgEuFqU8VZ4qfJlqCKpMJAss8OsHRDjLIvpJcX
    \\-----END PRIVATE KEY-----
;
