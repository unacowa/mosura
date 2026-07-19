// Cloudflare Workers エントリポイント (Mosura + Hyperdrive + postgres.js)
//
// セットアップ:
//   1. moon build --target js src/workers でエンジンをビルドし、
//      _build/js/debug/build/workers/workers.js を ./mosura.js にコピー
//   2. npm i postgres
//   3. wrangler.toml の Hyperdrive バインディングを設定
//   4. metadata.yaml をこのディレクトリに置き、ビルド時に取り込む
import postgres from "postgres";
import { mosura_plan, mosura_shape } from "./mosura.js";
import metadataYaml from "./metadata.yaml"; // wrangler の text ルールで取り込み

export default {
  async fetch(request, env) {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/graphql") {
      return new Response("not found", { status: 404 });
    }
    const body = await request.text();

    // 開発モードのセッション解決 (本番は JWT 等に置き換えること)
    const role = request.headers.get("x-hasura-role") ?? "admin";
    const sessionVars = {};
    for (const [k, v] of request.headers) {
      if (k.startsWith("x-hasura-") && k !== "x-hasura-role") sessionVars[k] = v;
    }

    // フェーズ1: GraphQL → SQL 計画 (純 MoonBit / 同期)
    const plan = JSON.parse(mosura_plan(metadataYaml, body, role, JSON.stringify(sessionVars)));
    if (plan.errors) {
      return Response.json(plan);
    }

    // フェーズ2: Hyperdrive 経由で SQL を実行 (プーリング・オリジン TLS は Hyperdrive が担う)
    const sql = postgres(env.HYPERDRIVE.connectionString, { max: 1 });
    const results = {};
    try {
      for (const q of plan.queries) {
        const rows = await sql.unsafe(q.sql, q.params);
        // 期待形状: 1 行 1 カラム (JSON 組み立て済み)
        const first = rows[0];
        results[q.alias] = JSON.stringify(first[Object.keys(first)[0]]);
      }
    } finally {
      await sql.end({ timeout: 1 });
    }

    // フェーズ3: レスポンス整形 (純 MoonBit / 同期)
    const response = mosura_shape(
      metadataYaml, body, role, JSON.stringify(sessionVars), JSON.stringify(results),
    );
    return new Response(response, { headers: { "Content-Type": "application/json" } });
  },
};
