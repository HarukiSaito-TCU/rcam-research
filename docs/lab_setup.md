# 研究室PCのセットアップ手順書（MATLABジョブ runner）

読み手：研究室PCで作業する人、または研究室PCのClaude Code。上から順に行えば終わるように書いています。
作業はすべて、研究室PCにユーザー `kiriki` でサインインした状態で、**管理者ではない普通の PowerShell**（Windows PowerShell 5.1）で行います。

以下の `<owner>/<repo>` は先輩のGitHubリポジトリ（以下「先輩repo」）の名前に置き換えてください。clone先は `C:\work\<repo>` です。

## 0. 始める前に（必ず読む）

研究室PCでは、別の研究（CRANE+のシミュレーション）が24時間動いています。次のものには、**読む以外の操作（変更・削除・停止・再起動）をしないでください**。

- フォルダ `C:\work\sindy-rl-winter`（中身すべて）、`%UserProfile%\.wslconfig`、WSL と `Ubuntu-24.04`
- タスク `CraneJobRunner`・`CraneWatchdog`・`SyncthingAutostart`
- Syncthingの既存のフォルダ（`sindy-rl-lab-outputs`）と、登録済みのデバイス
- `python.exe`・`pythonw.exe`・`wsl.exe`・Ray・Gazebo・ROS のプロセス。プロセスを名前で一括して止めること（`taskkill /IM ...`）は禁止です
- `git config --global` の設定と、`gh` のログイン状態

**困ったとき**：NG が出たとき、想定と違う表示が出たときは、そこで作業を止めてください。先輩repo・MATLAB・Deploy keyのことは先輩に、研究室PC・既存の研究・SyncthingのGUIパスワードのことは研究室PCの担当者に相談します。

用意するもの：

| もの | 誰が持っているか |
|---|---|
| 先輩repoの名前 `<owner>/<repo>` | 先輩 |
| 先輩のノートPCのSyncthingのデバイスID | 先輩 |
| 研究室PCのSyncthingのGUIのパスワード | 研究室PCの担当者 |
| Deploy keyの登録（GitHubでの操作） | 先輩 |

## 1. 既存の研究の状態を記録する（作業の前）

先輩repoはまだないので、ここでは記録だけを手で行います（clone後は `setup_lab.ps1 -Snapshot` で同じことができます）。

```powershell
git -C C:\work\sindy-rl-winter --no-optional-locks status --porcelain
Get-ScheduledTask -TaskName CraneJobRunner, CraneWatchdog | Format-Table TaskName, State
```

- 確認：1行目は何も表示されない（空）こと。2行目の状態（`Ready` / `Running` など）をメモする。
- SyncthingのGUI（http://127.0.0.1:8384）を開き、既存のフォルダが「Up to Date」で、エラーが0件であることを確かめてメモする。

## 2. 先輩repo専用の鍵を作り、読み取り専用で clone する

### 2.1 鍵を作る

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
Test-Path "$env:USERPROFILE\.ssh\senpai_repo_ed25519"
```

`False` と表示されたら、次を実行します。`True` と表示されたら、鍵はもうあります。上書きせずに先輩に相談してください。

```powershell
cmd /c --% ssh-keygen -t ed25519 -N "" -C "lab-pc-matlab-runner" -f "%USERPROFILE%\.ssh\senpai_repo_ed25519"
Get-Content "$env:USERPROFILE\.ssh\senpai_repo_ed25519.pub"
```

- 確認：`ssh-ed25519 AAAA... lab-pc-matlab-runner` という1行が表示される。
- この1行（公開鍵）を先輩に送ります。`.pub` が付いていない方（秘密鍵）は、絶対に送らないでください。

### 2.2 先輩がGitHubで Deploy key を登録する（先輩の作業）

先輩repoの GitHub のページで、Settings → Deploy keys → Add deploy key を開きます。

- Title：`lab-pc`
- Key：受け取った1行
- **Allow write access のチェックは外したまま**（読み取り専用）

### 2.3 clone する

```powershell
New-Item -ItemType Directory -Force C:\work | Out-Null
cd C:\work
git -c "core.sshCommand=ssh -i C:/Users/kiriki/.ssh/senpai_repo_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" clone git@github.com:<owner>/<repo>.git
git -C C:\work\<repo> config --local core.sshCommand "ssh -i C:/Users/kiriki/.ssh/senpai_repo_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes"
git -C C:\work\<repo> log -1 --oneline
```

- 確認：最後の行に、先輩repoの最新のcommitが1行表示される。
- `Permission denied (publickey)` と出たら、Deploy keyの登録がまだか、間違っています。先輩に確認してください。
- `git config --global` は使っていません。既存の研究の `gh` のログインにも触れていません。

## 3. セットアップスクリプトを実行する

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\work\<repo>\lab\setup_lab.ps1 -Snapshot
powershell -NoProfile -ExecutionPolicy Bypass -File C:\work\<repo>\lab\setup_lab.ps1
```

1行目は、既存の研究の状態を `results\setup\existing_research_<時刻>.txt` に記録します（読むだけです）。
2行目は、次のことを順に行います。各行に `OK` / `NG` / `SKIP` が表示され、`NG` が出るとそこで止まり、次に何をするかを表示します。記録は `C:\work\<repo>\results\setup\setup_report.txt` に残ります。

| 段階 | 内容 | NG のとき |
|---|---|---|
| repo | パスがASCIIでOneDrive配下でないこと、`results/` がgit管理外であること、repoローカルの `core.sshCommand`、`git fetch` ができること、作業ツリーがきれいなこと | 表示された指示に従う。分からなければ先輩へ |
| MATLAB | `matlab.exe` を探し（`C:\Program Files\MATLAB\R*\bin\matlab.exe` の一番新しいもの）、`matlab -batch "disp(version); exit(0)"` の終了コードが0になること、`matlab -batch "error(...)"` の終了コードが0以外になることを確かめる。`lab\config.json` にMATLABのパスを書く | **ライセンスのエラーが出たら、そこで止まって先輩と相談**。MATLABが別の場所にあれば `-MatlabExe "<...>\bin\matlab.exe"` を付けて実行し直す |
| 並列ワーカー | `Processes` クラスタープロファイルの `NumWorkers` を6にして保存する。Parallel Computing Toolbox がなければ `SKIP` と記録する | 先輩へ |
| Syncthing | `lab\lab_stignore.txt` を `C:\work\<repo>\.stignore` にコピーする（`results/` だけを同期する設定） | — |
| タスク | `lab\install_task.ps1 install` でタスク `MatlabJobRunner` を登録する（5分ごと、ユーザー権限、ログオン中のみ） | 「管理者権限が必要」と出たら、管理者権限は使わずに止まり、研究室PCの担当者へ |

MATLABの確認には1回あたり数分かかることがあります。最後に `DONE.` と表示されれば終わりです。

確認：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\work\<repo>\lab\install_task.ps1 status
```

`REGISTERED: MatlabJobRunner`、`logon=Interactive`、`runlevel=Limited`、`repetition interval : PT5M` と表示されること。5分ほど待つと `last task result : 0` になり、`C:\work\<repo>\results\jobs\runner_heartbeat.json` ができます。

## 4. Syncthing に先輩のフォルダを追加する（GUIでの操作）

既存のSyncthing（GUI：http://127.0.0.1:8384、パスワードは研究室PCの担当者が知っています）に、**フォルダを1つ追加するだけ**にします。既存のフォルダとデバイスの設定は開かないでください。

1. `C:\work\<repo>\.stignore` があることを確かめる（3.で作られています）。**フォルダを追加する前に**必要です。
   ```powershell
   Get-Content C:\work\<repo>\.stignore
   ```
   `!/results` と `*` の2行が表示されること。
2. 右下の「Add Remote Device」で、先輩のノートPCのデバイスIDを入れる。Device Name は `senpai-laptop`。**Sharing タブでは、既存のフォルダにチェックを入れない**。Save。
3. 左の「Add Folder」で次のように設定して Save。
   - General：Folder Label `senpai-matlab-results`、Folder ID `senpai-matlab-results`、Folder Path `C:\work\<repo>`
   - Sharing：`senpai-laptop` だけにチェック
   - Advanced：Folder Type を **Send Only**
4. 追加したフォルダの「Edit」→「Ignore Patterns」に `!/results` と `*` が表示されることを確かめる。
5. 研究室PCのデバイスIDは `QZFWXH7-V7Q5PZI-SG3FAI4-EH632AV-E6ES7T7-4IBPCDY-57GIRON-RLG6IAM` です。これを先輩のノートPCのSyncthingで登録してもらい、共有の申し出を受け入れてもらいます（先輩の作業）。
6. 既存のフォルダが、今までどおり「Up to Date」でエラー0件のままであることを確かめる。

## 5. 動作を確かめる（先輩と一緒に）

先輩が、先輩のノートPCから次の2つのジョブを push します（`lab/lab_check.m` はrepoに入っています）。

`jobs/20261014_lab_check.json`
```json
{"id": "20261014_lab_check", "entry": "lab/lab_check.m"}
```
`jobs/20261014_lab_check_error.json`
```json
{"id": "20261014_lab_check_error", "entry": "lab/lab_check.m", "vars": {"make_error": true}}
```

確かめること：

1. 5分以内に `C:\work\<repo>\results\jobs\20261014_lab_check\status.json` の `state` が `running` になり、終わると `finished` になる。`check.txt` に `maxNumCompThreads=6` と `MATLAB_MAX_WORKERS=6` が書かれている。同じファイルが、先輩のノートPCの受け取り先に届く。
2. 次の5分で `20261014_lab_check_error` が実行され、`failed` になる。`matlab.log` に `intentional test error` が残る。
3. 実行中に、タスクマネージャーの「詳細」タブで `MATLAB.exe` の優先度が「通常以下」であることを確かめる。画面にMATLABのウィンドウが出ていないことも確かめる。
4. 既存の研究に影響していないこと：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File C:\work\<repo>\lab\setup_lab.ps1 -Snapshot
   ```
   `results\setup\` にある作業前の記録と比べて、`C:\work\sindy-rl-winter` の `git status --porcelain` が空のままであること、`CraneJobRunner`・`CraneWatchdog` の状態が変わっていないことを確かめる。SyncthingのGUIで、既存のフォルダのエラーが0件であることを確かめる。

## 6. 困ったとき

| 症状 | 見るところ・すること |
|---|---|
| ジョブが始まらない | `results\jobs\runner_heartbeat.json` の `time`（5分以内に更新されているか）、`thisRun`、`lastError`。`results\jobs\runner.log` |
| `working tree not clean` | MATLABがgit管理下のフォルダにファイルを書いた。`git -C C:\work\<repo> status` で何かを確かめ、**消さずに先輩に連絡**する（出力先を `results/` の下に直してもらう） |
| `git pull --ff-only failed` | ネットワーク、またはDeploy key。`git -C C:\work\<repo> pull --ff-only` を手で実行してエラーを見る |
| `MATLAB not found` | `lab\config.json` の `matlabExe` のパスを確かめる |
| ジョブを止めたい | 先輩が `jobs/<id>.stop` を push する（5分以内に止まる）。MATLABを名前で止めないこと |
| 状態が `lost` | MATLABが `exitcode.txt` を書く前に消えた（再起動・サインアウトなど）。新しいidでやり直す |
| 仕組みを外す | `lab\install_task.ps1 uninstall`。実行中のMATLABは独立したプロセスなので、必要なら先に `.stop` で止める。Syncthingの `senpai-matlab-results` フォルダは GUI で Remove |

タスクは、ユーザー `kiriki` がサインインしている間だけ動きます。研究室PCが再起動して誰もサインインしていない間は、ジョブは始まりません（サインインすると、次の5分以内に再開します）。

## 付録：先輩のノートPCでの受け取りの準備

1. Syncthing を入れる（https://syncthing.net/downloads/ から Windows 版。SyncTrayzor などのGUI付きのものでもよい）。起動して、GUI（http://127.0.0.1:8384）の Actions → Show ID で自分のデバイスIDを確かめ、研究室PCの作業者に渡す。
2. Add Remote Device で研究室PCのデバイスID `QZFWXH7-V7Q5PZI-SG3FAI4-EH632AV-E6ES7T7-4IBPCDY-57GIRON-RLG6IAM` を登録する（Device Name は `lab-pc`）。
3. 研究室PCがフォルダ `senpai-matlab-results` を共有すると、GUIに「共有の申し出」が出る。Add を押して、次のように設定する。
   - Folder Path：**先輩repoの外の**、受け取り専用の空のフォルダ（例：`C:\Users\<you>\lab_results\<repo>`）。先輩repoの中にすると、受け取ったファイルが git の作業ツリーに混ざるので避ける。
   - Advanced：Folder Type を **Receive Only**
4. 受け取り先に `results\jobs\<id>\` が届く。研究室PCの `.stignore` で `results/` だけを送っているので、受け取り側には `.stignore` は不要です。
