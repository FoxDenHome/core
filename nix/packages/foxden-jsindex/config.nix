{ ... }:
{
  nginxConfig = ''
    location = /favicon.ico {
        root /njs/www;
    }

    location = /robots.txt {
        root /njs/www;
    }

    location = /_dori-static {
        return 301 /_dori-static/;
    }

    location /_dori-static/ {
        root /njs/www;
    }

    location = /_dori-static/_js/index {
        internal;
        js_content files.index;
    }

    location = /.well-known {
        return 301 /.well-known/;
    }

    location /.well-known/ {
        root /njs/www;
    }

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Strict-Transport-Security "max-age=31536000; preload; includeSubDomains" always;

    location / {
      set $request_original_filename $request_filename;
      index /_dori-static/_js/index;
    }
  '';
}
