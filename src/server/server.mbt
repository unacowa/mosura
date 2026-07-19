// GraphQL HTTP エンドポイント (native / moonbitlang/async/http)

///|
/// POST /graphql を処理するサーバを起動する (戻らない)
pub async fn run_server(
  ctx : @engine.EngineContext,
  executor : &@exec.SqlExecutor,
  port : Int,
) -> Unit {
  let addr = @socket.Addr::parse("0.0.0.0:\{port}")
  let server = @http.Server::Server(addr)
  println("mosura: listening on 0.0.0.0:\{port} (POST /graphql)")
  server.run_forever(async fn(request, body_reader, conn) {
    match (request.meth, request.path) {
      (Post, "/graphql") => {
        // セッション解決 (AuthConfig が無ければ admin)
        let session = @session.resolve_session(ctx.meta.auth, request.headers) catch {
          @session.Unauthorized(msg) => {
            conn.send_response(401, "Unauthorized", extra_headers={
              "Content-Type": "application/json",
            })
            conn.write_string(@engine.error_response(msg).stringify())
            conn.end_response()
            return
          }
        }
        let body_text = body_reader.read_all().text() catch {
            _ => {
              conn.send_response(400, "Bad Request")
              conn.write_string("{\"errors\":[{\"message\":\"invalid body\"}]}")
              conn.end_response()
              return
            }
          }
        let body_json = @json.parse(body_text) catch {
          _ => {
            conn.send_response(400, "Bad Request", extra_headers={
              "Content-Type": "application/json",
            })
            conn.write_string(
              "{\"errors\":[{\"message\":\"request body is not valid JSON\"}]}",
            )
            conn.end_response()
            return
          }
        }
        let response = @engine.execute_request(
          ctx, session, executor, body_json,
        )
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "application/json",
        })
        conn.write_string(response.stringify())
        conn.end_response()
      }
      (Get, "/healthz") => {
        conn.send_response(200, "OK")
        conn.write_string("ok")
        conn.end_response()
      }
      _ => {
        conn.send_response(404, "Not Found")
        conn.write_string("not found")
        conn.end_response()
      }
    }
  })
}
