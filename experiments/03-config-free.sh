#!/usr/bin/env bash
# Experiment 3: S3 operations with NO rclone.conf, four different ways, and
# with different credentials/endpoints per operation.
#
#   A. connection string   :s3,provider=...,endpoint='...':bucket
#   B. command-line flags  --s3-endpoint ... :s3:bucket
#   C. env vars, unnamed   RCLONE_S3_*        -> :s3:bucket
#   D. env vars, named     RCLONE_CONFIG_<NAME>_* -> name:bucket
#
# Usage: experiments/03-config-free.sh | tee results/logs/03-config-free.log
source "$(dirname "$0")/lib.sh"
clear_s3_env
EMPTY_CONF="$DATA/empty-rclone.conf"
: > "$EMPTY_CONF"

section "0. Prove there is no usable config"
run 'rclone config file'
run 'ls -l ~/.config/rclone/rclone.conf 2>&1   # the default path does not exist either'
note "an explicitly EMPTY config file works the same way:"
run 'rclone --config data/empty-rclone.conf listremotes; echo "remotes defined: $(rclone --config data/empty-rclone.conf listremotes | wc -l)"'

section "A. On-the-fly connection string"
note "every setting inside the remote name; values containing : or , must be quoted"
run 'rclone --config data/empty-rclone.conf mkdir ":s3,provider=Other,endpoint='"'"'$S3_A_ENDPOINT'"'"',access_key_id=$S3_A_ACCESS_KEY,secret_access_key=$S3_A_SECRET_KEY:config-free"'
run 'rclone --config data/empty-rclone.conf copy data/source/pdfs ":s3,provider=Other,endpoint='"'"'$S3_A_ENDPOINT'"'"',access_key_id=$S3_A_ACCESS_KEY,secret_access_key=$S3_A_SECRET_KEY:config-free/via-connection-string" -v'
note "downside: the secret is part of the command line -> visible in ps, shell history, CI logs"

section "B. Backend flags"
run 'rclone --config data/empty-rclone.conf lsf -R :s3:config-free --s3-provider Other --s3-endpoint "$S3_A_ENDPOINT" --s3-access-key-id "$S3_A_ACCESS_KEY" --s3-secret-access-key "$S3_A_SECRET_KEY"'
note "same downside as A: secrets in argv"

section "C. Environment variables for the unnamed :s3: backend"
note "every --s3-xxx flag can be given as RCLONE_S3_XXX"
run 'export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT="$S3_A_ENDPOINT" RCLONE_S3_ACCESS_KEY_ID="$S3_A_ACCESS_KEY" RCLONE_S3_SECRET_ACCESS_KEY="$S3_A_SECRET_KEY"'
run 'rclone --config data/empty-rclone.conf copy data/source/docs :s3:config-free/via-env -v'
run 'rclone --config data/empty-rclone.conf tree :s3:config-free'
note "limitation: only ONE set of :s3: settings at a time"
run 'clear_s3_env'

section "D. Named remotes defined only by environment variables"
note "RCLONE_CONFIG_<NAME>_<OPTION> creates remote <name>: in memory. Two providers, two credential sets, at once:"
run 'export RCLONE_CONFIG_PROVA_TYPE=s3 RCLONE_CONFIG_PROVA_PROVIDER=Other RCLONE_CONFIG_PROVA_ENDPOINT="$S3_A_ENDPOINT" RCLONE_CONFIG_PROVA_ACCESS_KEY_ID="$S3_A_ACCESS_KEY" RCLONE_CONFIG_PROVA_SECRET_ACCESS_KEY="$S3_A_SECRET_KEY"'
run 'export RCLONE_CONFIG_PROVB_TYPE=s3 RCLONE_CONFIG_PROVB_PROVIDER=Other RCLONE_CONFIG_PROVB_ENDPOINT="$S3_B_ENDPOINT" RCLONE_CONFIG_PROVB_ACCESS_KEY_ID="$S3_B_ACCESS_KEY" RCLONE_CONFIG_PROVB_SECRET_ACCESS_KEY="$S3_B_SECRET_KEY"'
run 'rclone --config data/empty-rclone.conf listremotes   # remotes exist, yet the config file is empty'
run 'rclone --config data/empty-rclone.conf mkdir provb:replica'

section "E. Different credentials + endpoints in ONE operation"
note "copy endpoint A -> endpoint B: each side authenticates with its own keys"
run 'rclone --config data/empty-rclone.conf copy prova:config-free provb:replica -v'
run 'rclone --config data/empty-rclone.conf check prova:config-free provb:replica'
note "styles are interchangeable: a connection string with endpoint B keys reads what the named remote provb: wrote"
run 'rclone --config data/empty-rclone.conf lsf ":s3,provider=Other,endpoint='"'"'$S3_B_ENDPOINT'"'"',access_key_id=$S3_B_ACCESS_KEY,secret_access_key=$S3_B_SECRET_KEY:replica"'

section "F. Credentials really are checked"
note "endpoint B's keys against endpoint A must fail"
run 'rclone --config data/empty-rclone.conf lsd :s3: --s3-provider Other --s3-endpoint "$S3_A_ENDPOINT" --s3-access-key-id "$S3_B_ACCESS_KEY" --s3-secret-access-key "$S3_B_SECRET_KEY" --retries 1 --low-level-retries 1'

section "G. The config file is still empty"
run 'wc -c data/empty-rclone.conf; ls ~/.config/rclone/ 2>&1'
