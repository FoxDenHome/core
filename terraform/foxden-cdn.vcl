sub vcl_recv { 
#FASTLY recv

  set req.http.transport-type = transport.type;
  set req.http.tls-protocol = tls.client.protocol;
  set req.http.tls-cipher = tls.client.cipher;

  set req.http.static-response-body = table.lookup(static_root, req.url.path);
  if (req.http.static-response-body) {
    set req.http.static-response-meta = table.lookup(static_root, req.url.path + ".meta");
    set req.http.static-response-tmp = req.http.static-response-meta:status;
    if (req.http.static-response-tmp) {
      error std.atoi(req.http.static-response-tmp);
    }
    error 200;
  }

  unset req.http.static-response-meta;
  if (req.url.path == "/info/ip") {
    set req.http.static-response-body = client.ip + LF;
    error 200;
  }

  if (req.url.path == "/info/proto") {
    set req.http.static-response-body = req.http.transport-type + LF;
    error 200;
  }

  if (req.url.path == "/info/tls") {
    set req.http.static-response-meta:content-type = "application/json";
    if (req.is_ssl) {
      set req.http.static-response-body = {"{
  "enabled": true,
  "version": ""} + json.escape(req.http.tls-protocol) + {"",
  "cipher": ""} + json.escape(req.http.tls-cipher) + {""
}"};
    } else {
      set req.http.static-response-body = {"{
  "enabled": false
}"};
    }
    error 200;
  }

  # If we ever have a real backend, we need to swap these sections below

  set req.http.static-response-body = "Not found" + LF;
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

  if (obj.status < 200 || obj.status > 499) {
    return(deliver);
  }

  set obj.http.Cache-Control = "no-store";
  unset obj.http.Retry-After;

  set obj.http.Content-Type = "text/plain";
  if (req.http.static-response-meta) {
    set req.http.static-response-tmp = req.http.static-response-meta:content-type;
    if (req.http.static-response-tmp) {
      set obj.http.Content-Type = req.http.static-response-tmp;
    }
  }

  synthetic req.http.static-response-body;
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
