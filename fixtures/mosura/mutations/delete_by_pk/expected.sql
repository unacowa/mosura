WITH "mut" AS (DELETE FROM "public"."article" WHERE ("id" = 10) RETURNING "id" AS "id") SELECT coalesce(json_agg(row_to_json("mut")), '[]') AS "rows" FROM "mut";

{}
