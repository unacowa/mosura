// mosura serve --metadata <file|dir> [--port 8080]

///|
fn usage() -> Unit {
  println("usage: mosura serve --metadata <file|dir> [--port 8080]")
  println(
    "  接続先はメタデータの DataConnectorLink (url / urlFromEnv) から解決します",
  )
  println("  接続文字列形式: postgres://user:pass@host:port/dbname")
}

///|
/// postgres://user:pass@host:port/db をパース
fn parse_pg_url(url : String) -> (String, Int, String, String, String)? {
  let prefix = if url.has_prefix("postgres://") {
    "postgres://"
  } else if url.has_prefix("postgresql://") {
    "postgresql://"
  } else {
    return None
  }
  let rest = url[prefix.length():].to_owned()
  let at = rest.find("@")
  let (userinfo, hostpart) = match at {
    Some(i) => (rest[0:i].to_owned(), rest[i + 1:].to_owned())
    None => ("postgres", rest)
  }
  let (user, password) = match userinfo.find(":") {
    Some(i) => (userinfo[0:i].to_owned(), userinfo[i + 1:].to_owned())
    None => (userinfo, "")
  }
  let (hostport, db) = match hostpart.find("/") {
    Some(i) => (hostpart[0:i].to_owned(), hostpart[i + 1:].to_owned())
    None => (hostpart, "postgres")
  }
  let (host, port) = match hostport.find(":") {
    Some(i) => {
      let p = hostport[i + 1:].to_owned()
      let port = @string.parse_int(p) catch { _ => return None }
      (hostport[0:i].to_owned(), port)
    }
    None => (hostport, 5432)
  }
  Some((host, port, user, password, db))
}

///|
fn load_metadata_from(path : String) -> Result[@metadata.Metadata, String] {
  let text = read_metadata_text(path) catch {
    _ => return Err("cannot read metadata path: \{path}")
  }
  let meta = @metadata.load_yaml(text) catch { m => return Err(m.display()) }
  Ok(meta)
}

///|
fn read_metadata_text(path : String) -> String raise {
  if @fs.is_dir(path) {
    let files = @fs.read_dir(path)
    files.sort()
    let sb = StringBuilder::new()
    for f in files {
      if f.has_suffix(".yaml") || f.has_suffix(".yml") {
        sb.write_string(@fs.read_file_to_string("\{path}/\{f}"))
        sb.write_string("\n---\n")
      }
    }
    sb.to_string()
  } else {
    @fs.read_file_to_string(path)
  }
}

///|
async fn main {
  let args = @env.args()
  // args[0] = 実行ファイル
  let mut metadata_path : String? = None
  let mut port = 8080
  let mut command : String? = None
  let mut i = 1
  while i < args.length() {
    match args[i] {
      "serve" => command = Some("serve")
      "--metadata" => {
        i += 1
        if i < args.length() {
          metadata_path = Some(args[i])
        }
      }
      "--port" => {
        i += 1
        if i < args.length() {
          port = @string.parse_int(args[i]) catch { _ => 8080 }
        }
      }
      _ => ()
    }
    i += 1
  }
  if command != Some("serve") || metadata_path is None {
    usage()
    return
  }
  let metadata_path = metadata_path.unwrap()
  let meta = match load_metadata_from(metadata_path) {
    Ok(m) => m
    Err(msg) => {
      println("mosura: failed to load metadata: \{msg}")
      return
    }
  }
  let ctx = @engine.EngineContext::new(meta) catch {
    _ => {
      println("mosura: failed to build schema")
      return
    }
  }
  // 接続先の解決 (最初の connector を使用)
  let mut url : String? = None
  for _, link in meta.connectors {
    url = match (link.url, link.url_from_env) {
      (Some(u), _) => Some(u)
      (None, Some(env_name)) => @env.get_env_var(env_name)
      _ => None
    }
  }
  let url = match url {
    Some(u) => u
    None => {
      println(
        "mosura: no connection url (set the environment variable referenced by urlFromEnv)",
      )
      return
    }
  }
  let (host, pg_port, user, password, db) = match parse_pg_url(url) {
    Some(x) => x
    None => {
      println("mosura: invalid postgres url")
      return
    }
  }
  @async.with_task_group(group => {
    let config = @client.Config::new(
      host,
      port=pg_port,
      user~,
      database=db,
      password~,
      ssl_mode=@client.SslMode::Disable,
      application_name="mosura",
    )
    let (executor, connection) = @native.NativeExecutor::connect(config)
    group.spawn_bg(() => connection.run())
    println("mosura: connected to \{host}:\{pg_port}/\{db}")
    @server.run_server(ctx, executor, port)
  }) catch {
    _ => println("mosura: server terminated with error")
  }
}
