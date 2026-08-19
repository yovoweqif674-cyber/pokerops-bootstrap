import os
import pathlib
import sys
import tempfile


def extract_patcher(helper: pathlib.Path) -> str:
    text = helper.read_text(encoding='utf-8')
    anchor = "NGINX_PATCHED_VALUE=\"$work_dir/nginx-site-patched.conf\""
    start = text.index(anchor)
    start = text.index("python3 <<'PY'", start) + len("python3 <<'PY'")
    start = text.index('\n', start) + 1
    end = text.index('\nPY\n', start)
    return text[start:end]


def run_patcher(code: str, source: pathlib.Path, target: pathlib.Path) -> None:
    old = dict(os.environ)
    try:
        os.environ['NGINX_SOURCE_VALUE'] = str(source)
        os.environ['NGINX_PATCHED_VALUE'] = str(target)
        os.environ['WEB_ROOT_VALUE'] = '/var/www/pokerops'
        exec(compile(code, '<embedded-nginx-patcher>', 'exec'), {})
    finally:
        os.environ.clear()
        os.environ.update(old)


def main() -> None:
    helper = pathlib.Path(sys.argv[1]).resolve()
    code = extract_patcher(helper)
    fixture = '''server {
    listen 443 ssl;
    server_name forprofit.pro www.forprofit.pro;
    root /var/www/pokerops;
    index index.html;

    location /assets/ {
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
'''

    with tempfile.TemporaryDirectory(prefix='pokerops-nginx-patch-') as raw:
        root = pathlib.Path(raw)
        original = root / 'pokerops.conf'
        first = root / 'first.conf'
        second = root / 'second.conf'
        original.write_text(fixture, encoding='utf-8')

        run_patcher(code, original, first)
        first_text = first.read_text(encoding='utf-8')
        assert first_text.count('# BEGIN POKEROPS TOURNAMENT INGESTION') == 1
        assert 'proxy_pass http://127.0.0.1:8787/;' in first_text
        assert 'if ($request_method !~ ^(GET|HEAD)$)' in first_text
        assert 'location ^~ /tournament-ingestion-api/internal/' in first_text
        assert 'location /assets/' in first_text
        assert 'location / {' in first_text

        run_patcher(code, first, second)
        second_text = second.read_text(encoding='utf-8')
        assert second_text.count('# BEGIN POKEROPS TOURNAMENT INGESTION') == 1
        assert second_text.count('proxy_pass http://127.0.0.1:8787/;') == 1

    print('nginx_patch_fixture=PASS')


if __name__ == '__main__':
    main()
