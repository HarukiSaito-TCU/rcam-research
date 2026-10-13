# jobs/ ：研究室PCで実行するMATLABジョブ

ここに `<job_id>.json` を置いて push すると、研究室PCのタスク `MatlabJobRunner` が5分以内に取り込み、未実行のジョブを1つずつ、idの順に実行します。

```json
{
  "id": "20261013_duffing_sweep_a",
  "entry": "src/run_sweep.m",
  "vars": {"gamma": 0.3, "omega_list": [0.8, 1.0, 1.2], "tag": "a"},
  "note": "人が読むための説明（任意）"
}
```

- `id`：ファイル名（`.json` を除く）と同じにする。使える文字は英数字・`_`・`-` だけ。日付から始めると、並べたときに実行順になります。
- `entry`：repo内の `.m` ファイルを、repoのルートからの相対パスで書く。`..` や絶対パスは使えません。ファイル名はMATLABの名前として正しいもの（英字で始まり、英数字と `_` だけ）にしてください。
- `vars`（任意）：`run` の前にMATLABの変数として代入されます。使える値は、数、文字列（改行なし）、`true`/`false`、数の配列だけです。変数名は `^[A-Za-z][A-Za-z0-9_]*$` に合うもの。`JOB_ID` と `JOB_OUT` は予約されています。
- entry は `run` で実行されるので、実行中の現在のフォルダは entry のあるフォルダになります（MATLABの `run` の仕様）。repoのルートは `JOB_OUT` の3つ上のフォルダ（`fileparts(fileparts(fileparts(JOB_OUT)))`）です。
- 出力は必ず `JOB_OUT`（`results/jobs/<id>/`）の下に書いてください。git管理下のフォルダにファイルを書くと、研究室PCのrunnerはpullも新しいジョブの起動もしなくなります。
- MATLABは、計算スレッドが6まで（`maxNumCompThreads(6)`）、並列ワーカーが6まで（環境変数 `MATLAB_MAX_WORKERS=6`）、優先度「通常以下」で動きます。メモリは約20 GB までにしてください。

## 結果

研究室PCの `results/jobs/<id>/` に次のファイルができ、Syncthingで先輩のノートPCに届きます。

- `status.json`：`state` は `running` / `finished` / `failed` / `rejected`（`reason` に理由）/ `cancelled` / `stopped` / `lost`
- `matlab.log`：MATLABの出力とエラー
- `exitcode.txt`：MATLABの終了コード
- ジョブの出力

runner全体の状態は `results/jobs/runner_heartbeat.json`（5分ごとに更新）と `results/jobs/runner.log` で確認できます。

## 止める・やり直す

- まだ始まっていないジョブを取り消す：空のファイル `jobs/<id>.cancel` を push する。
- 実行中のジョブを止める：空のファイル `jobs/<id>.stop` を push する（次の5分以内に止まり、`stopped` になります）。
- 一度 `status.json` ができたジョブは、二度と実行されません。やり直すときは、新しいidでジョブを作ってください。
