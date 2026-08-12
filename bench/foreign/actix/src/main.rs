use actix_web::{post, get, web, App, HttpResponse, HttpServer, Responder};

#[get("/")]
async fn index() -> impl Responder {
    HttpResponse::Ok().body("")
}

#[post("/echo")]
async fn echo(body: web::Bytes) -> impl Responder {
    HttpResponse::Ok().body(body)
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let port: u16 = std::env::args().nth(1).and_then(|p| p.parse().ok()).unwrap_or(8080);
    let workers: usize = std::env::args().nth(2).and_then(|w| w.parse().ok()).unwrap_or(4);
    HttpServer::new(|| App::new().service(index).service(echo))
        .bind(("127.0.0.1", port))?
        .workers(workers)
        .run()
        .await
}
