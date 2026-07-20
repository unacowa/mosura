WITH "mut" AS (INSERT INTO "public"."article" ("id", "title") VALUES (20, cast($1 as "text")) RETURNING "id" AS "id", NOT (("public"."article"."author_id" = 2)) AS "%check__violation") SELECT coalesce(json_agg(row_to_json("mut")), '[]') AS "rows" FROM "mut";

{
    1: String(
        "checked",
    ),
}
