WITH "mut" AS (UPDATE "public"."article" SET "author_id" = 3 WHERE ("id" = 20) AND (("public"."article"."author_id" = 2)) RETURNING "id" AS "id", "author_id" AS "author_id", NOT (("public"."article"."author_id" = 2)) AS "%check__violation") SELECT coalesce(json_agg(row_to_json("mut")), '[]') AS "rows" FROM "mut";

{}
