//! Test fixtures shared across the TLS module: an ECDSA P-256 certificate
//! and key pair (self-signed, generated with openssl) used by the unit and
//! integration tests, plus a client CA + client certificate pair (openssl,
//! 2026-10) for mTLS verification tests.

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
pub const client_ca_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBjDCCATGgAwIBAgIUF8G0LfcT3kJ6frUyi+2OJ9WlRQ0wCgYIKoZIzj0EAwIw
    \\GzEZMBcGA1UEAwwQem9ja2V0LWNsaWVudC1jYTAeFw0yNjEwMDgwNDI4MDlaFw0z
    \\NjEwMDUwNDI4MDlaMBsxGTAXBgNVBAMMEHpvY2tldC1jbGllbnQtY2EwWTATBgcq
    \\hkjOPQIBBggqhkjOPQMBBwNCAAStuaB6WKR+jt3Ymo8kIJN6Sl1IWQ8WELNDd5Kp
    \\hmIokJOkpSy+dAlrha07znz1V0k3g2r8kT6e5ACnhLEugBjNo1MwUTAdBgNVHQ4E
    \\FgQUm6fMT2sZpNsRHEXUd2NdzTIwnBkwHwYDVR0jBBgwFoAUm6fMT2sZpNsRHEXU
    \\d2NdzTIwnBkwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAlkiv
    \\hZxNDt+orP2/2xFa/rXwY6yROVW2BZ1G0m6wOq8CIQDMKMLTuP+yWs6CZIHtV3pu
    \\PrFphw/y/88pNn/NGv6ltg==
    \\-----END CERTIFICATE-----
;

pub const client_cert_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBpDCCAUqgAwIBAgIUBXOBb9HBXuXpqqNSMWTWF7kKWnEwCgYIKoZIzj0EAwIw
    \\GzEZMBcGA1UEAwwQem9ja2V0LWNsaWVudC1jYTAeFw0yNjEwMDgwNDI4MDlaFw0z
    \\NjEwMDUwNDI4MDlaMBgxFjAUBgNVBAMMDXpvY2tldC1jbGllbnQwWTATBgcqhkjO
    \\PQIBBggqhkjOPQMBBwNCAARAFDfLRO25cJ7Qtvj9aNh+mbZ7iieqry97W7Fq6pWc
    \\iKzjOgZekqlC2QKliOuxRDo/N4Df4gTFIROTbc8fP+Bko28wbTAJBgNVHRMEAjAA
    \\MAsGA1UdDwQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAjAdBgNVHQ4EFgQUs4VC
    \\GKF6z+yAn/T+uXxd8+vnCYAwHwYDVR0jBBgwFoAUm6fMT2sZpNsRHEXUd2NdzTIw
    \\nBkwCgYIKoZIzj0EAwIDSAAwRQIhAI30jBxIXWmZQX2e0sTY7zD3wHDjPHFhtjlJ
    \\94+/WhjcAiBUn0p/+dTFYwCCsYfsLzmwEpiw6p8ng+S1SbdyMSEioQ==
    \\-----END CERTIFICATE-----
;
pub const client_key_pem =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEIAtwpdulBhPF7VVyB/89FHhJgUtun3wCCPO/cF7gXd1IoAoGCCqGSM49
    \\AwEHoUQDQgAEQBQ3y0TtuXCe0Lb4/WjYfpm2e4onqq8ve1uxauqVnIis4zoGXpKp
    \\QtkCpYjrsUQ6PzeA3+IExSETk23PHz/gZA==
    \\-----END EC PRIVATE KEY-----
;
