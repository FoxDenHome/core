sub vcl_recv { 
#FASTLY recv

  unset req.http.resp-meta;
  unset req.http.resp-body;

  set req.http.resp-body = table.lookup(static_root, req.url.path);
  if (req.http.resp-body) {
    set req.http.resp-meta = table.lookup(static_root, req.url.path + ".meta");
    set req.http.resp-tmp = req.http.resp-meta:status;
    if (req.http.resp-tmp) {
      error std.atoi(req.http.resp-tmp);
    }
    error 200;
  }

  if (req.url.path == "/ip") {
    set req.http.resp-body = digest.base64(client.ip + LF);
    error 200;
  }

  if (req.url.path == "/connection.json") {
    set req.http.resp-meta:content-type = "application/json";
    set req.http.resp-body = digest.base64({"{
  "ip": ""} + json.escape(client.ip) + {"",
  "transport": ""} + json.escape(transport.type) + if(req.is_ssl, {"",
  "tls": {
    "version": ""} + json.escape(tls.client.protocol) + {"",
    "cipher": ""} + json.escape(tls.client.cipher) + {""
  }"}, "%22") + {"
}"} + LF);
    error 200;
  }

  # If we ever have a real backend, we need to swap these sections below

  set req.http.resp-body = digest.base64("Not found" + LF);
  error 404;

  # if (req.method != "HEAD" && req.method != "GET" && req.method != "FASTLYPURGE") {
  #   return(pass);
  # }
  # # Image optimization code here if in use
  # return(lookup);
}

sub vcl_hash {
  set req.hash += req.url;
  set req.hash += req.http.host;
#FASTLY hash
  return(hash);
}

sub vcl_hit {
#FASTLY hit
  return(deliver);
}

sub vcl_miss {
#FASTLY miss
  return(fetch);
}

sub vcl_pass {
#FASTLY pass
  return(pass);
}

sub vcl_fetch {
#FASTLY fetch
  return(pass);
}

sub vcl_error {
#FASTLY error

  if (!req.http.resp-body) {
    return(deliver);
  }

  set obj.http.Content-Type = "text/plain";
  set obj.http.Cache-Control = "no-store";
  unset obj.http.Retry-After;

  if (req.http.resp-meta) {
    set obj.http.Content-Type = req.http.resp-meta:content-type;
  }

  synthetic.base64 req.http.resp-body;
  return(deliver);
}

sub vcl_deliver {
#FASTLY deliver

  # Unset headers that Fastly set that makes no sense in edge-only scenarios
  unset resp.http.X-Cache-Hits;
  unset resp.http.X-Cache;

  return(deliver);
}

sub vcl_log {
#FASTLY log
}
