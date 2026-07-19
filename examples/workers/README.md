# Mosura on Cloudflare Workers (Hyperdrive)

Mosura のエンジン (GraphQL パース → 権限 → SQL 生成 → レスポンス整形) は
純 MoonBit のまま JS にコンパイルされ、SQL の実行だけを Workers 側の
postgres.js + Hyperdrive に委譲する 2 フェーズ構成です。

```
リクエスト → mosura_plan() ──SQL群──▶ postgres.js (Hyperdrive) ──結果──▶ mosura_shape() → レスポンス
             (MoonBit/js)                                                (MoonBit/js)
```

## 手順

1. エンジンのビルド:
   ```sh
   moon build --target js src/workers
   cp _build/js/debug/build/workers/workers.js examples/workers/mosura.js
   ```
2. メタデータ (`metadata.yaml`) をこのディレクトリに配置
3. Hyperdrive を作成し `wrangler.toml` に ID を設定:
   ```sh
   wrangler hyperdrive create mosura-db --connection-string="postgres://..."
   ```
4. 依存を入れてデプロイ:
   ```sh
   npm i postgres
   wrangler deploy
   ```

## 注意

- Hyperdrive がプーリングとオリジンへの TLS を担うため、Worker 側の接続設定は不要です
- セッション解決は開発モード (ヘッダ信頼)。本番では JWT 検証を worker.js に実装してください
