// リレーション経路 order by の拒否・グループ化のテスト。
// テーブル定義は sorting_by_nested_relationship_column フィクスチャの
// configuration.json (album / artist / track) を流用する

///|
const SORTING_CONFIG = "fixtures/ndc-postgres-translation/goldenfiles/sorting_by_nested_relationship_column/configuration.json"

///|
fn decode_sorting_request(
  request_text : String,
) -> (PgMetadata, QueryRequest) raise {
  let config = @json.parse(@fs.read_file_to_string(SORTING_CONFIG))
  let metadata = decode_pg_metadata(config)
  let request = decode_query_request(@json.parse(request_text))
  (metadata, request)
}

///|
test "order by: 配列リレーション越しのカラムソートは拒否される (終端要素)" {
  let request =
    #|{
    #|  "collection": "album",
    #|  "query": {
    #|    "fields": { "id": { "type": "column", "column": "album_id", "arguments": {} } },
    #|    "order_by": {
    #|      "elements": [
    #|        {
    #|          "order_direction": "asc",
    #|          "target": {
    #|            "type": "column",
    #|            "name": "name",
    #|            "path": [
    #|              { "relationship": "AlbumTracks", "arguments": {}, "predicate": null }
    #|            ]
    #|          }
    #|        }
    #|      ]
    #|    }
    #|  },
    #|  "arguments": {},
    #|  "collection_relationships": {
    #|    "AlbumTracks": {
    #|      "column_mapping": { "album_id": ["album_id"] },
    #|      "relationship_type": "array",
    #|      "target_collection": "track",
    #|      "arguments": {}
    #|    }
    #|  }
    #|}
  let (metadata, decoded) = decode_sorting_request(request)
  try translate_query_request(metadata, decoded) |> ignore catch {
    NotImplemented(_) => ()
    _ => fail("expected NotImplemented")
  } noraise {
    _ => fail("expected NotImplemented (array relationship ordering)")
  }
}

///|
test "order by: 経路の中間が配列リレーションでも拒否される (raw NDC 経由)" {
  // album -[array]-> track -[object]-> album の title でソート。
  // 中間要素の array を黙認すると JOIN が複数行を返し外側の行数が壊れる
  let request =
    #|{
    #|  "collection": "album",
    #|  "query": {
    #|    "fields": { "id": { "type": "column", "column": "album_id", "arguments": {} } },
    #|    "order_by": {
    #|      "elements": [
    #|        {
    #|          "order_direction": "asc",
    #|          "target": {
    #|            "type": "column",
    #|            "name": "title",
    #|            "path": [
    #|              { "relationship": "AlbumTracks", "arguments": {}, "predicate": null },
    #|              { "relationship": "TrackAlbum", "arguments": {}, "predicate": null }
    #|            ]
    #|          }
    #|        }
    #|      ]
    #|    }
    #|  },
    #|  "arguments": {},
    #|  "collection_relationships": {
    #|    "AlbumTracks": {
    #|      "column_mapping": { "album_id": ["album_id"] },
    #|      "relationship_type": "array",
    #|      "target_collection": "track",
    #|      "arguments": {}
    #|    },
    #|    "TrackAlbum": {
    #|      "column_mapping": { "album_id": ["album_id"] },
    #|      "relationship_type": "object",
    #|      "target_collection": "album",
    #|      "arguments": {}
    #|    }
    #|  }
    #|}
  let (metadata, decoded) = decode_sorting_request(request)
  try translate_query_request(metadata, decoded) |> ignore catch {
    NotImplemented(_) => ()
    _ => fail("expected NotImplemented")
  } noraise {
    _ => fail("expected NotImplemented (intermediate array relationship)")
  }
}

///|
test "order by: field_path 付き対象はデコード時に拒否される (黙殺しない)" {
  let request =
    #|{
    #|  "collection": "album",
    #|  "query": {
    #|    "fields": { "id": { "type": "column", "column": "album_id", "arguments": {} } },
    #|    "order_by": {
    #|      "elements": [
    #|        {
    #|          "order_direction": "asc",
    #|          "target": {
    #|            "type": "column",
    #|            "name": "title",
    #|            "path": [],
    #|            "field_path": ["nested"]
    #|          }
    #|        }
    #|      ]
    #|    }
    #|  },
    #|  "arguments": {},
    #|  "collection_relationships": {}
    #|}
  let parsed = @json.parse(request)
  try decode_query_request(parsed) |> ignore catch {
    NdcDecode(_) => ()
  } noraise {
    _ => fail("expected NdcDecode (field_path not supported)")
  }
}

///|
test "order by: 異なる2経路は別 JOIN、同一経路は JOIN を共有する" {
  // 3要素: [TrackAlbum].title (asc) / [TrackAlbum, AlbumArtist].name (desc) /
  // [TrackAlbum].album_id (asc)。1番目と3番目は同一経路なので JOIN を共有し、
  // ORDER BY はリクエストの要素順を保つ
  let request =
    #|{
    #|  "collection": "track",
    #|  "query": {
    #|    "fields": { "id": { "type": "column", "column": "track_id", "arguments": {} } },
    #|    "order_by": {
    #|      "elements": [
    #|        {
    #|          "order_direction": "asc",
    #|          "target": {
    #|            "type": "column",
    #|            "name": "title",
    #|            "path": [
    #|              { "relationship": "TrackAlbum", "arguments": {}, "predicate": null }
    #|            ]
    #|          }
    #|        },
    #|        {
    #|          "order_direction": "desc",
    #|          "target": {
    #|            "type": "column",
    #|            "name": "name",
    #|            "path": [
    #|              { "relationship": "TrackAlbum", "arguments": {}, "predicate": null },
    #|              { "relationship": "AlbumArtist", "arguments": {}, "predicate": null }
    #|            ]
    #|          }
    #|        },
    #|        {
    #|          "order_direction": "asc",
    #|          "target": {
    #|            "type": "column",
    #|            "name": "album_id",
    #|            "path": [
    #|              { "relationship": "TrackAlbum", "arguments": {}, "predicate": null }
    #|            ]
    #|          }
    #|        }
    #|      ]
    #|    }
    #|  },
    #|  "arguments": {},
    #|  "collection_relationships": {
    #|    "TrackAlbum": {
    #|      "column_mapping": { "album_id": ["album_id"] },
    #|      "relationship_type": "object",
    #|      "target_collection": "album",
    #|      "arguments": {}
    #|    },
    #|    "AlbumArtist": {
    #|      "column_mapping": { "artist_id": ["artist_id"] },
    #|      "relationship_type": "object",
    #|      "target_collection": "artist",
    #|      "arguments": {}
    #|    }
    #|  }
    #|}
  let (metadata, decoded) = decode_sorting_request(request)
  let sql = translate_query_request(metadata, decoded)
  inspect(
    normalize_sql_text(sql.sql),
    content=(
      #|SELECT coalesce(json_agg(row_to_json("%7_universe")),'[]') AS "universe" FROM(SELECT * FROM(SELECT coalesce(json_agg(row_to_json("%8_rows")),'[]') AS "rows" FROM(SELECT "%1_track"."TrackId" AS "id" FROM(SELECT "%0_track".* FROM "public"."Track" AS "%0_track") AS "%1_track" LEFT OUTER JOIN LATERAL(SELECT "%2_ORDER_PART_album"."Title" AS "Title","%2_ORDER_PART_album"."AlbumId" AS "AlbumId" FROM(SELECT "%2_ORDER_PART_album"."Title" AS "Title","%2_ORDER_PART_album"."AlbumId" AS "AlbumId" FROM "public"."Album" AS "%2_ORDER_PART_album" WHERE("%1_track"."AlbumId" = "%2_ORDER_PART_album"."AlbumId")) AS "%2_ORDER_PART_album") AS "%3_ORDER_FOR_track" ON('true') LEFT OUTER JOIN LATERAL(SELECT "%5_ORDER_PART_artist"."Name" AS "Name" FROM(SELECT "%4_ORDER_PART_album"."ArtistId" AS "ArtistId" FROM "public"."Album" AS "%4_ORDER_PART_album" WHERE("%1_track"."AlbumId" = "%4_ORDER_PART_album"."AlbumId")) AS "%4_ORDER_PART_album" LEFT OUTER JOIN LATERAL(SELECT "%5_ORDER_PART_artist"."Name" AS "Name" FROM "public"."Artist" AS "%5_ORDER_PART_artist" WHERE("%4_ORDER_PART_album"."ArtistId" = "%5_ORDER_PART_artist"."ArtistId")) AS "%5_ORDER_PART_artist" ON('true')) AS "%6_ORDER_FOR_track" ON('true') ORDER BY "%3_ORDER_FOR_track"."Title" ASC,"%6_ORDER_FOR_track"."Name" DESC,"%3_ORDER_FOR_track"."AlbumId" ASC) AS "%8_rows") AS "%8_rows") AS "%7_universe"
    ),
  )
}
