sub vcl_recv { 
#FASTLY recv

  set req.http.transport-type = transport.type;
  set req.http.tls-protocol = tls.client.protocol;
  set req.http.tls-cipher = tls.client.cipher;
  error 989 "vcl_error redirect";
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

table static_responses {
  "/nm-check.txt": "NetworkManager is online",
}

sub vcl_error {
#FASTLY error

  if (obj.status != 989) {
    return(deliver);
  }

  set obj.status = 200;
  set obj.response = "OK";
  set obj.http.content-type = "text/plain";
  set obj.http.cache-control = "no-store";
  unset obj.http.Retry-After;

  set req.http.foxden-static-response = table.lookup(static_responses, req.url.path);
  if (req.http.foxden-static-response) {
    synthetic req.http.foxden-static-response + LF;
    return(deliver);
  }

  if (req.url.path == "/info/ip") {
    synthetic client.ip;
    return(deliver);
  }

  if (req.url.path == "/info/proto") {
    synthetic req.http.transport-type;
    return(deliver);
  }

  if (req.url.path == "/info/tls") {
    set obj.http.content-type = "application/json";
    if (req.is_ssl) {
      synthetic {"{
  "enabled": true,
  "version": ""} + json.escape(req.http.tls-protocol) + {"",
  "cipher": ""} + json.escape(req.http.tls-cipher) + {""
}"};
    } else {
      synthetic {"{
  "enabled": false
}"};
    }
    return(deliver);
  }

  set obj.status = 404;
  set obj.response = "Not found";
  synthetic "Not found" + LF;
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
