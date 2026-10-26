#!/usr/bin/env python3
"""Use one persistent local signing certificate. Never change system trust or TCC."""
import os
import pathlib
import secrets
import shlex
import subprocess
import sys
import tempfile

def run(*args, capture=False):
    try:
        return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None).stdout
    except subprocess.CalledProcessError as error:
        # Arguments can contain keychain passwords; never include them in logs.
        raise RuntimeError("Signing step failed: " + pathlib.Path(args[0]).name + " (exit " + str(error.returncode) + ")") from None

root = pathlib.Path.home() / "Library/Application Support/SpySigning"
root.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(root, 0o700)
keychain = root / "Spy.keychain-db"
password_file = root / "keychain-password"
cert = root / "Spy-Signing.cer"
if not keychain.exists():
    password = secrets.token_urlsafe(32)
    password_file.write_text(password)
    os.chmod(password_file, 0o600)
    search_list = shlex.split(run("/usr/bin/security", "list-keychains", "-d", "user", capture=True))
    try:
        run("/usr/bin/security", "create-keychain", "-p", password, str(keychain))
        with tempfile.TemporaryDirectory(prefix="Spy-signing-", dir=root) as temporary:
            folder = pathlib.Path(temporary)
            config = folder / "certificate.conf"
            config.write_text('''[req]
distinguished_name = name
x509_extensions = signing
prompt = no
[name]
CN = Spy Local Code Signing
O = Spy Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
            run("/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-config", str(config), "-keyout", str(folder / "private.pem"), "-out", str(folder / "certificate.pem"))
            run("/usr/bin/openssl", "x509", "-in", str(folder / "certificate.pem"), "-outform", "der", "-out", str(cert))
            run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(folder / "private.pem"), "-in", str(folder / "certificate.pem"), "-out", str(folder / "identity.p12"), "-passout", "pass:" + password)
            run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain))
            run("/usr/bin/security", "import", str(folder / "identity.p12"), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign")
            run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain), capture=True)
    finally:
        run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *search_list)
password = password_file.read_text()
run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain))
fingerprint = run("/usr/bin/openssl", "x509", "-inform", "der", "-in", str(cert), "-noout", "-fingerprint", "-sha1", capture=True).strip().split("=")[1].replace(":", "")
search_list = shlex.split(run("/usr/bin/security", "list-keychains", "-d", "user", capture=True))
try:
    # codesign also uses the search list to resolve the certificate chain.
    # Restore the user's original list even when signing fails.
    run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *search_list, str(keychain))
    run("/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain), "--timestamp=none", "--identifier", "local.spy.mac", sys.argv[1])
finally:
    run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *search_list)
run("/usr/bin/codesign", "--verify", "--deep", "--strict", sys.argv[1])
print("Persistent local signing certificate: " + fingerprint)
