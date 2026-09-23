# Secrets manifest

Secret VALUES cannot be exported (the API returns `value: null`).
Recreate each secret below in the TARGET **before** importing, keeping the
same identifier and scope. Connectors/pipelines reference them by identifier.

## Scope: account
- [ ] `mp_harness_private_key`  (type: SecretFile, name: mp_harness_private_key)

## Scope: default/KarpoInfra
- [ ] `openrouter_api_key`  (type: SecretText, name: openrouter_api_key)
- [ ] `cloudflare_api_token`  (type: SecretText, name: cloudflare_api_token)
- [ ] `feishu_routing_config`  (type: SecretText, name: feishu_routing_config)
- [ ] `datadog_app_key`  (type: SecretText, name: datadog_app_key)
- [ ] `datadog_api_key`  (type: SecretText, name: datadog_api_key)
- [ ] `harness_sa_api_key`  (type: SecretText, name: harness_sa_api_key)
- [ ] `argus_harness_pat`  (type: SecretText, name: argus_harness_pat)
- [ ] `argus_harness_webhook_secret`  (type: SecretText, name: argus_harness_webhook_secret)
- [ ] `dd_cv_api_key`  (type: SecretText, name: dd_cv_api_key)
- [ ] `dd_cv_app_key`  (type: SecretText, name: dd_cv_app_key)

## Scope: default/Alice
- [ ] `vercel_promote_token`  (type: SecretText, name: vercel_promote_token)
- [ ] `CLOUDFLARE_ADMIN_TOKEN`  (type: SecretText, name: CLOUDFLARE_ADMIN_TOKEN)
- [ ] `alice_staging_cf_client_secret`  (type: SecretText, name: alice_staging_cf_client_secret)
- [ ] `alice_staging_cf_client_id`  (type: SecretText, name: alice_staging_cf_client_id)
- [ ] `ALICE_RELEASE_CF_CLIENT_SECRET`  (type: SecretText, name: ALICE_RELEASE_CF_CLIENT_SECRET)
- [ ] `ALICE_RELEASE_CF_CLIENT_ID`  (type: SecretText, name: ALICE_RELEASE_CF_CLIENT_ID)
- [ ] `harness_sa_api_key`  (type: SecretText, name: harness_sa_api_key)
- [ ] `openrouter_api_key`  (type: SecretText, name: openrouter_api_key)

