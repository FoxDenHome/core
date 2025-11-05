from refresh.util import mtik_path, MTikUser

SCRIPT_DIR = mtik_path("script")

DEFAULT_DONTREQUIREPERMS = False
DEFAULT_POLICY = "ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon"

# TODO: Use API and diff in Python and then synchronize stuff instead of generating a big script (use comment as id)

def refresh_scripts(user: MTikUser) -> None:
    print("## TODO")
