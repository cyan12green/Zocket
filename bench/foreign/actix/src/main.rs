use actix_files::NamedFile;
use actix_web::{get, post, web, App, HttpResponse, HttpServer, Responder};

#[get("/")]
async fn index() -> impl Responder {
    HttpResponse::Ok().body("")
}

#[post("/echo")]
async fn echo(body: web::Bytes) -> impl Responder {
    HttpResponse::Ok().body(body)
}

// Static benchmark file: served from disk via NamedFile (sendfile on Linux);
// path from ACTIX_STATIC (set by compare-servers.sh), defaults to ./static.
// open_async matches what actix-web's own Files service does (open() would
// block the tokio workers and tank the benchmark).
#[get("/static")]
async fn static_file() -> actix_web::Result<NamedFile> {
    let path = std::env::var("ACTIX_STATIC").unwrap_or_else(|_| "static".into());
    Ok(NamedFile::open_async(path).await?)
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let port: u16 = std::env::args().nth(1).and_then(|p| p.parse().ok()).unwrap_or(8080);
    let workers: usize = std::env::args().nth(2).and_then(|w| w.parse().ok()).unwrap_or(4);
    HttpServer::new(|| App::new().service(index).service(echo).service(static_file))
        .bind(("127.0.0.1", port))?
        .workers(workers)
        // Config parity: nginx (default), Caddy and Bun all enable
        // TCP_NODELAY; actix-http's default is off, which produces a
        // Nagle/delayed-ACK interlock (two-part head+body writes stall
        // ~40 ms) on this workload.
        .tcp_nodelay(true)
        .run()
        .await
}
