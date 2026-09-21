# Privacy

brain-graph は個人の閲覧履歴を材料にする。したがって、何が公開され、何が手元に留まり、
どこへ送られるのかを曖昧にしない。この文書はその境界を定義する。

## Repository

このリポジトリは public であり、含まれるのはスキーマとプロンプトとドキュメントだけである。
収集されたデータは一切含めない。履歴そのもの、抽出された URL、生成されたタグ、
データベースのダンプは、いかなる形でもコミットしない。

この方針の帰結として、このリポジトリを fork しても他人の閲覧履歴は入手できない。
fork した利用者は自分の Turso データベースを作り、自分の履歴だけを蓄積する。

## Credentials

Turso の接続先とトークンは手元の環境にのみ置く。保管場所はリポジトリの外、
`~/.config/brain-graph/env` とし、パーミッションは `600` にする。

```shell
mkdir -p ~/.config/brain-graph
chmod 600 ~/.config/brain-graph/env
```

リポジトリの `.gitignore` は `.env` と `.env.*` 、および `*.db` と `*.sqlite` を除外する。
これは事故を防ぐ二重の備えであって、リポジトリ内に秘密情報を置いてよい理由にはならない。
トークンが漏れた場合は `turso db tokens invalidate brain-graph` で全トークンを失効させ、
発行し直す。

## Exclusions

閲覧履歴には、認証セッションを含む URL や、私信・金融・医療といった機微な情報が混ざる。
そこで収集の段階で除外リストを適用し、該当する URL はデータベースにもモデルにも渡さない。
除外パターンの一覧は [ingest.md](../ingest.md) の Exclusions 節が単一の正であり、
この文書では重複して列挙しない。

除外に加えて、残った URL からはクエリ文字列とフラグメントを取り除く。
トラッキングパラメータとセッション識別子は、これだけで大半が落ちる。

## Deletion

記録済みのデータは URL のパターンを指定して削除できる。
`visits` と `has_tag` は `urls` への外部キーに `ON DELETE CASCADE` を持つため、
`urls` から消せば関連する訪問とタグも同時に消える。

```sql
DELETE FROM urls WHERE url LIKE 'https://example.com/%';
```

訪問記録だけを消してタグの構造を残したい場合は、 `visits` を直接指定する。

```sql
DELETE FROM visits WHERE url_id IN (SELECT id FROM urls WHERE url LIKE ?);
```

どのタグにも結び付かなくなったタグ名を掃除するには、孤立した行を削除する。

```sql
DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM has_tag);
```

## Transmission

データの送信先は二つだけであり、いずれも利用者自身が契約した相手である。
第三者への送信、解析サービスへの送信、広告目的の利用はいずれも行わない。

- Turso には URL とタイトル、タグ、訪問時刻を保存する。データベースは利用者のアカウントに属する。
- Anthropic の Claude モデルには、タグを推論する目的で URL とタイトルを送る。ページ本文は送らない。

除外リストに該当する URL は、この二つのどちらにも送られない。
