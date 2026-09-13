<#
.SYNOPSIS
	全プロセスのメモリ使用状況と起動時刻を調査し、HTML レポートを出力する。

.DESCRIPTION
	Win32_Process・Win32_Service・Get-Process の情報を突き合わせ、メモリ使用量の
	多い順に並べた HTML レポートを logs フォルダへ書き出す。
	Windows PowerShell 5.1 で動作する。

	出力先は logs/yyyy/yyyymm/yyyymmdd/yyyymmdd-hhmmss-mem-<権限>-log.html。
	<権限> は管理者なら admin、そうでなければ user。

	あわせて logs/ に記録を残す。
	  last-report.txt      直近 1 件（cmd が読む）
	  reports-admin.txt    管理者で取った履歴（追記）
	  reports-user.txt     非管理者で取った履歴（追記）

	メモリ使用量は SVG の横棒グラフで表示し、各プロセスが何を実行しているのかを
	日本語で補う。svchost などサービスをホストするプロセスは、ホストしている
	サービスの表示名を並べる。

	個人情報の保護のため、ユーザープロファイルのパス・ユーザー名・コンピューター名は
	出力前に置き換える。

.PARAMETER OutDir
	出力先のルートフォルダ。既定はスクリプトから見た ..\..\logs。
	この下に yyyy/yyyymm/yyyymmdd/ を作って書き出す。

.PARAMETER TopCount
	グラフに載せる上位件数。既定 30。

.PARAMETER Open
	出力後、既定のブラウザで開く。

.PARAMETER Pause
	終了時にキー入力を待つ。管理者昇格で別ウィンドウが開いたときに使う。
#>
[CmdletBinding()]
param(
	[string]$OutDir,
	[int]$TopCount = 30,
	[switch]$Open,
	[switch]$Pause,
	[switch]$NoElevate,
	[string]$SubstDrive,
	[string]$SubstRoot
)

$ErrorActionPreference = 'Stop'

# ==================================================================
# 共通の小道具
# ==================================================================

$script:sb = New-Object System.Text.StringBuilder

function Add-Html([string]$Text) {
	[void]$script:sb.AppendLine($Text)
}

# & < > の順で置き換える。& を後にすると二重に変換される
function ConvertTo-HtmlText([string]$Text) {
	if ([string]::IsNullOrEmpty($Text)) { return '' }
	$r = $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
	# 値に混じった改行・タブは空白へ潰す。
	# コマンドラインに改行を含むプロセスがあり、そのまま出すと出力の改行が混在する
	$r = $r -replace "[`r`n`t]+", ' '
	return $r
}

function ConvertTo-HtmlAttr([string]$Text) {
	return (ConvertTo-HtmlText $Text).Replace('"', '&quot;')
}

# ユーザー名・コンピューター名を伏せる。出力にローカル PC 固有の情報を残さない
$script:UserProfile = $env:USERPROFILE
$script:UsersRoot = Split-Path -Parent $script:UserProfile
$script:UserName = $env:USERNAME
$script:ComputerName = $env:COMPUTERNAME

function Hide-Private([string]$Text) {
	if ([string]::IsNullOrEmpty($Text)) { return $Text }
	$r = $Text
	# 昇格したプロセスは実体パスで起動されるため、元のドライブ表記に戻す。
	# ユーザー名の置換より先に行う（実体パスがユーザープロファイル配下にある場合、
	# 先に伏せ字化されるとドライブ表記へ戻せなくなる）
	# 引数は昇格の再起動でしか渡らないため、渡っていなければ起動時に引き当てた値を使う
	$substRootUsed = $SubstRoot
	$substDriveUsed = $SubstDrive
	if (-not $substRootUsed) {
		$substRootUsed = $script:FoundSubstRoot
		$substDriveUsed = $script:FoundSubstDrive
	}
	if ($substRootUsed -and $substDriveUsed) {
		$r = $r -replace [regex]::Escape($substRootUsed), $substDriveUsed
	}
	if ($script:UserProfile) {
		# 後ろが区切りでないときは別のフォルダ（プロファイル名で始まるだけ）なので置換しない。
		# 置換すると残りの文字が見えてしまう。その場合は次の規則が要素ごと伏せる
		$r = $r -replace ([regex]::Escape($script:UserProfile) + '(?![^\\/:"'' ])'), '~'
	}
	# ユーザー SID。Windows Search 等がパイプ名やレジストリキーの一部に埋め込むため、
	# パス・ユーザー名の伏せ字化では拾えない経路で漏れる（実際に SearchProtocolHost.exe の
	# コマンドラインで見つかった）。ローカル／ドメインの SID は S-1-5-21-<3つの数字>-<RID> の形
	$r = $r -replace 'S-1-5-21-\d+-\d+-\d+-\d+', '<sid>'
	if ($script:UsersRoot) {
		$r = $r -replace ([regex]::Escape($script:UsersRoot) + '[\\/][^\\/"'' ]+'), 'C:\Users\<username>'
	}
	if ($script:UserName) {
		# 部分一致で置換すると、ユーザー名で始まるフォルダ名の残りが見えてしまう。
		# 区切りに挟まれた要素ごと伏せる
		$r = $r -replace ('(?<![^\\/:"'' ])[^\\/:"'' ]*' + [regex]::Escape($script:UserName) + '[^\\/:"'' ]*'), '<username>'
	}
	if ($script:ComputerName) {
		# ユーザー名と同じ理由で、区切りに挟まれた要素ごと伏せる
		$r = $r -replace ('(?<![^\\/:"'' ])[^\\/:"'' ]*' + [regex]::Escape($script:ComputerName) + '[^\\/:"'' ]*'), '<hostname>'
	}
	return $r
}

# subst で割り当てたドライブは、UAC で昇格したプロセスからは存在しない。
# 昇格前にパスを実体へ直しておく。割り当てが見つかったら、戻すための対応も控える
$script:FoundSubstDrive = ''
$script:FoundSubstRoot = ''

function Resolve-SubstPath([string]$Path) {
	$root = [System.IO.Path]::GetPathRoot($Path)
	if (-not $root) { return $Path }
	$drive = $root.TrimEnd('\')
	if ($drive.Length -ne 2) { return $Path }

	foreach ($line in (subst)) {
		# subst の出力は「N:\: => C:\〈実体フォルダ〉」の形
		$m = [regex]::Match([string]$line, '^\s*([A-Za-z]:)\\:\s+=>\s+(.+?)\s*$')
		if ($m.Success -and $m.Groups[1].Value -eq $drive) {
			$script:FoundSubstDrive = $drive
			$script:FoundSubstRoot = $m.Groups[2].Value
			return $m.Groups[2].Value + $Path.Substring($drive.Length)
		}
	}
	return $Path
}

# subst の割り当てを実体パスの側から引き当てる。Resolve-SubstPath はドライブ文字から
# 引くため、実体パスで起動された場合は当たらない。ここを通さないと実体パスが出力に残る
function Find-SubstRoot([string]$Path) {
	if ([string]::IsNullOrEmpty($Path)) { return }
	foreach ($line in (subst)) {
		$m = [regex]::Match([string]$line, '^\s*([A-Za-z]:)\\:\s+=>\s+(.+?)\s*$')
		if (-not $m.Success) { continue }
		$root = $m.Groups[2].Value.TrimEnd('\')
		if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
			$script:FoundSubstDrive = $m.Groups[1].Value
			$script:FoundSubstRoot = $root
			return
		}
	}
}

# 昇格の引数で渡っていないときだけ引き当てる（渡っている値を上書きしない）
if (-not $SubstRoot) { Find-SubstRoot $PSScriptRoot }

function Format-MB([double]$Bytes) {
	return ('{0:N1}' -f ($Bytes / 1MB))
}

# [int] は切り捨てではなく四捨五入するため、上位の単位だけが繰り上がって下位と重複する
# （9.995 日が「10日 23時間 53分」になる）。上位は Floor で切り捨てる
function Format-Span($Span) {
	if ($null -eq $Span) { return '-' }
	if ($Span.TotalDays -ge 1) {
		return ('{0}日 {1}時間 {2}分' -f $Span.Days, $Span.Hours, $Span.Minutes)
	}
	if ($Span.TotalHours -ge 1) {
		return ('{0}時間 {1}分' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes)
	}
	return ('{0}分 {1}秒' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Format-Pct([double]$Value) {
	return ('{0:N1}' -f $Value)
}

# SVG の座標・幅に使う数値。N 書式は桁区切りのカンマが入り、属性値として無効になる
function Format-Coord([double]$Value) {
	return $Value.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

# ==================================================================
# プロセスが何を実行しているのかを日本語で補う
# ==================================================================

# 実行ファイル名（小文字）→ 日本語の説明。
# FileVersionInfo の説明は英語のことが多いため、辞書に載っているものはこちらを優先する
$script:ProcNotes = @{
	'system'                        = 'Windows カーネルとドライバー'
	'idle'                          = 'CPU アイドル（実体のないプロセス）'
	'registry'                      = 'レジストリのメモリ常駐領域'
	'memory compression'            = '圧縮メモリの保管領域'
	'smss.exe'                      = 'セッション マネージャー（起動の最初期処理）'
	'csrss.exe'                     = 'クライアント／サーバー ランタイム（コンソール・スレッド管理）'
	'wininit.exe'                   = 'Windows 起動処理'
	'winlogon.exe'                  = 'ログオン処理'
	'services.exe'                  = 'サービス制御マネージャー'
	'lsass.exe'                     = 'ローカル セキュリティ機関（認証・パスワード検証）'
	'svchost.exe'                   = 'Windows サービスのホスト'
	'fontdrvhost.exe'               = 'フォント ドライバー ホスト'
	'dwm.exe'                       = 'デスクトップ ウィンドウ マネージャー（画面の合成・描画）'
	'explorer.exe'                  = 'エクスプローラー（デスクトップ・タスクバー・ファイル操作）'
	'taskhostw.exe'                 = 'タスク ホスト（スケジュールされた処理の入れ物）'
	'runtimebroker.exe'             = 'ストアアプリの権限仲介'
	'sihost.exe'                    = 'シェル インフラストラクチャ ホスト'
	'ctfmon.exe'                    = 'テキスト入力（IME）の管理'
	'searchindexer.exe'             = '検索インデックスの作成'
	'searchhost.exe'                = '検索 UI（スタートの検索ボックス）'
	'searchapp.exe'                 = '検索 UI'
	'startmenuexperiencehost.exe'   = 'スタート メニュー'
	'shellexperiencehost.exe'       = 'シェル UI（通知センター等）'
	'textinputhost.exe'             = '入力候補・絵文字パネル'
	'applicationframehost.exe'      = 'ストアアプリの表示枠'
	'msmpeng.exe'                   = 'Microsoft Defender ウイルス対策エンジン'
	'nissrv.exe'                    = 'Microsoft Defender ネットワーク検査'
	'mpdefendercoreservice.exe'     = 'Microsoft Defender コア サービス'
	'securityhealthservice.exe'     = 'Windows セキュリティの状態監視'
	'securityhealthsystray.exe'     = 'Windows セキュリティの通知アイコン'
	'audiodg.exe'                   = 'オーディオ処理（音声のミキシング・効果）'
	'spoolsv.exe'                   = '印刷スプーラー'
	'conhost.exe'                   = 'コンソール ウィンドウの表示'
	'dllhost.exe'                   = 'COM サロゲート（DLL を代理実行）'
	'wmiprvse.exe'                  = 'WMI プロバイダー ホスト（システム情報の提供）'
	'backgroundtaskhost.exe'        = 'バックグラウンド タスク'
	'backgroundtransferhost.exe'    = 'バックグラウンド転送'
	'systemsettings.exe'            = '設定アプリ'
	'lockapp.exe'                   = 'ロック画面'
	'wudfhost.exe'                  = 'ユーザーモード ドライバー ホスト'
	'sppsvc.exe'                    = 'ライセンス認証'
	'wlanext.exe'                   = '無線 LAN の拡張処理'
	'unsecapp.exe'                  = 'WMI の非同期通知受け口'
	'taskmgr.exe'                   = 'タスク マネージャー'
	'perfmon.exe'                   = 'パフォーマンス モニター'
	'mmc.exe'                       = '管理コンソール'
	'onedrive.exe'                  = 'OneDrive の同期'
	'widgets.exe'                   = 'ウィジェット'
	'widgetservice.exe'             = 'ウィジェットのサービス'
	'phoneexperiencehost.exe'       = 'スマートフォン連携'
	'yourphone.exe'                 = 'スマートフォン連携'
	'gamebar.exe'                   = 'Xbox Game Bar'
	'gamebarftserver.exe'           = 'Xbox Game Bar の補助'
	'msedgewebview2.exe'            = 'Edge WebView2（アプリに埋め込まれたブラウザ）'
	'msedge.exe'                    = 'Microsoft Edge'
	'chrome.exe'                    = 'Google Chrome'
	'firefox.exe'                   = 'Mozilla Firefox'
	'brave.exe'                     = 'Brave ブラウザ'
	'code.exe'                      = 'Visual Studio Code'
	'devenv.exe'                    = 'Visual Studio'
	'node.exe'                      = 'Node.js'
	'deno.exe'                      = 'Deno'
	'bun.exe'                       = 'Bun'
	'powershell.exe'                = 'Windows PowerShell 5.1'
	'pwsh.exe'                      = 'PowerShell 7'
	'cmd.exe'                       = 'コマンド プロンプト'
	'windowsterminal.exe'           = 'Windows ターミナル'
	'openconsole.exe'               = 'Windows ターミナルのコンソール ホスト'
	'bash.exe'                      = 'Bash'
	'wsl.exe'                       = 'WSL の起動口'
	'wslservice.exe'                = 'WSL のサービス'
	'wslhost.exe'                   = 'WSL のホスト'
	'vmmem'                         = 'WSL2／Hyper-V 仮想マシンのメモリ'
	'vmmemwsl'                      = 'WSL2 仮想マシンのメモリ'
	'vmcompute.exe'                 = 'Hyper-V の計算サービス'
	'docker desktop.exe'            = 'Docker Desktop'
	'com.docker.backend.exe'        = 'Docker のバックエンド'
	'python.exe'                    = 'Python'
	'pythonw.exe'                   = 'Python（ウィンドウなし）'
	'java.exe'                      = 'Java'
	'javaw.exe'                     = 'Java（ウィンドウなし）'
	'ruby.exe'                      = 'Ruby'
	'git.exe'                       = 'Git'
	'ssh.exe'                       = 'SSH クライアント'
	'excel.exe'                     = 'Microsoft Excel'
	'winword.exe'                   = 'Microsoft Word'
	'powerpnt.exe'                  = 'Microsoft PowerPoint'
	'outlook.exe'                   = 'Microsoft Outlook'
	'onenote.exe'                   = 'Microsoft OneNote'
	'msaccess.exe'                  = 'Microsoft Access'
	'teams.exe'                     = 'Microsoft Teams'
	'ms-teams.exe'                  = 'Microsoft Teams'
	'slack.exe'                     = 'Slack'
	'discord.exe'                   = 'Discord'
	'obsidian.exe'                  = 'Obsidian'
	'notion.exe'                    = 'Notion'
	'zoom.exe'                      = 'Zoom'
	'everything.exe'                = 'Everything（ファイル検索）'
	'claude.exe'                    = 'Claude デスクトップ'
	'notepad.exe'                   = 'メモ帳'
	'sublime_text.exe'              = 'Sublime Text'
	'7zfm.exe'                      = '7-Zip'
	'thunderbird.exe'               = 'Thunderbird'
	'steam.exe'                     = 'Steam'
	'steamwebhelper.exe'            = 'Steam の内蔵ブラウザ'
	'nvcontainer.exe'               = 'NVIDIA のコンテナー サービス'
	'nvidia web helper.exe'         = 'NVIDIA の補助処理'
	'igfxem.exe'                    = 'Intel グラフィックスの補助'
	'rtkauduservice64.exe'          = 'Realtek オーディオのサービス'
	'ipfsvc.exe'                    = 'Intel の管理サービス'
	'ctrlaltdel.exe'                = 'ログオン UI の補助'
	'sedsvc.exe'                    = 'Windows 修復サービス'
	'msoia.exe'                     = 'Office のテレメトリ収集'
	'officeclicktorun.exe'          = 'Office のクイック実行'
	'dropbox.exe'                   = 'Dropbox の同期'
	'googledrivefs.exe'             = 'Google ドライブの同期'
	'alexa.exe'                     = 'Amazon Alexa'
	'acrobat.exe'                   = 'Adobe Acrobat'
	'acrord32.exe'                  = 'Adobe Acrobat Reader'
	'adobecollabsync.exe'           = 'Adobe Acrobat の共同作業の同期'
	'armsvc.exe'                    = 'Adobe の更新サービス'
	'nvdisplay.container.exe'       = 'NVIDIA ディスプレイ ドライバーのコンテナー'
	'nvidia share.exe'              = 'NVIDIA オーバーレイ'
	'dsaservice.exe'                = 'Intel ドライバー＆サポート アシスタント'
	'dsatray.exe'                   = 'Intel ドライバー＆サポート アシスタント（通知アイコン）'
	'esrv_svc.exe'                  = 'Intel Energy Server サービス'
	'hp-one-agent-service.exe'      = 'HP One Agent サービス'
	'hpmedianetwork.exe'            = 'HP Media Network'
	'sysinfocap.exe'                = 'HP システム情報の収集'
	'touchpointanalyticsclientservice.exe' = 'HP Touchpoint Analytics（利用状況の収集）'
	'omencommandcenterbackground.exe'      = 'HP OMEN Command Center'
	'lightstudio-background.exe'    = 'HP OMEN Light Studio（イルミネーション制御）'
	'hpcommrecovery.exe'            = 'HP 通信の復旧'
	'apphelpercap.exe'              = 'HP App Helper'
	'mmsshost.exe'                  = 'McAfee のスキャン ホスト'
	'cnmnsst2.exe'                  = 'Canon ネットワーク スキャナー'
	'nasnavi.exe'                   = 'NAS Navigator'
	'winvnc.exe'                    = 'VNC サーバー（画面共有）'
	'rustdesk.exe'                  = 'RustDesk（遠隔操作）'
	'mery.exe'                      = 'Mery（テキストエディター）'
}

# ==================================================================
# カテゴリ分類
# ==================================================================

# 実行ファイル名（小文字）をカテゴリごとに並べる。
# 表示順を保ちたいので [ordered] を使う。「その他」は辞書に載せず、既定として扱う
$script:CategoryMembers = [ordered]@{
	'Windows 本体' = @(
		'system', 'system idle process', 'idle', 'secure system', 'registry', 'memory compression',
		'smss.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe', 'lsass.exe',
		'svchost.exe', 'fontdrvhost.exe', 'dwm.exe', 'explorer.exe', 'taskhostw.exe',
		'runtimebroker.exe', 'sihost.exe', 'ctfmon.exe', 'searchindexer.exe', 'searchhost.exe',
		'searchapp.exe', 'startmenuexperiencehost.exe', 'shellexperiencehost.exe',
		'textinputhost.exe', 'applicationframehost.exe', 'audiodg.exe', 'spoolsv.exe',
		'conhost.exe', 'dllhost.exe', 'wmiprvse.exe', 'backgroundtaskhost.exe',
		'backgroundtransferhost.exe', 'systemsettings.exe', 'lockapp.exe', 'wudfhost.exe',
		'sppsvc.exe', 'wlanext.exe', 'unsecapp.exe', 'taskmgr.exe', 'perfmon.exe', 'mmc.exe',
		'widgets.exe', 'widgetservice.exe', 'phoneexperiencehost.exe', 'yourphone.exe',
		'gamebar.exe', 'gamebarftserver.exe', 'rundll32.exe', 'ctrlaltdel.exe', 'sedsvc.exe',
		'presentationfontcache.exe', 'wermgr.exe', 'sppextcomobj.exe', 'smartscreen.exe',
		'searchprotocolhost.exe', 'searchfilterhost.exe', 'tabtip.exe', 'shellhost.exe',
		'gamingservices.exe', 'gamingservicesnet.exe', 'xboxpcappft.exe', 'xboxpcapp.exe',
		'xboxpctray.exe', 'crossdeviceresume.exe', 'usocoreworker.exe', 'mousocoreworker.exe',
		'trustedinstaller.exe', 'tiworker.exe', 'compattelrunner.exe', 'dashost.exe',
		'devicecensus.exe', 'dwwin.exe', 'lsaiso.exe', 'wsappx.exe'
	)
	'セキュリティ' = @(
		'msmpeng.exe', 'nissrv.exe', 'mpdefendercoreservice.exe',
		'securityhealthservice.exe', 'securityhealthsystray.exe', 'mpcmdrun.exe'
	)
	'ブラウザ' = @(
		'chrome.exe', 'msedge.exe', 'firefox.exe', 'brave.exe', 'msedgewebview2.exe',
		'opera.exe', 'vivaldi.exe', 'iexplore.exe'
	)
	'開発ツール' = @(
		'code.exe', 'devenv.exe', 'node.exe', 'deno.exe', 'bun.exe', 'electron.exe',
		'powershell.exe', 'pwsh.exe', 'cmd.exe', 'windowsterminal.exe', 'openconsole.exe',
		'bash.exe', 'wsl.exe', 'wslservice.exe', 'wslhost.exe', 'vmmem', 'vmmemwsl',
		'vmcompute.exe', 'docker desktop.exe', 'com.docker.backend.exe',
		'python.exe', 'pythonw.exe', 'java.exe', 'javaw.exe', 'ruby.exe', 'git.exe',
		'ssh.exe', 'sublime_text.exe', 'claude.exe', 'mery.exe', 'notepad.exe',
		'lm studio.exe', 'ollama.exe', 'ollama app.exe',
		'node-ai-chat-lite.exe', 'node-ai-chat-lite-winsw.exe',
		'remoting_host.exe', 'remoting_native_messaging_host.exe'
	)
	'業務アプリ' = @(
		'excel.exe', 'winword.exe', 'powerpnt.exe', 'outlook.exe', 'onenote.exe',
		'msaccess.exe', 'msoia.exe', 'officeclicktorun.exe',
		'teams.exe', 'ms-teams.exe', 'slack.exe', 'discord.exe', 'zoom.exe',
		'obsidian.exe', 'notion.exe', 'thunderbird.exe',
		'acrobat.exe', 'acrord32.exe', 'adobecollabsync.exe', 'armsvc.exe',
		'adobeipcbroker.exe', 'creative cloud.exe', 'adobe desktop service.exe'
	)
	'クラウドストレージ' = @(
		'onedrive.exe', 'filecoauth.exe',
		'dropbox.exe', 'dropboxupdate.exe',
		'googledrivefs.exe', 'googledrivesync.exe', 'backupandsync.exe',
		'megasync.exe', 'pcloud.exe', 'boxsync.exe', 'boxdrive.exe',
		'nextcloud.exe', 'syncthing.exe'
	)
	'メーカー製ユーティリティ' = @(
		'nvdisplay.container.exe', 'nvcontainer.exe', 'nvidia web helper.exe',
		'nvidia share.exe', 'nvsphelper64.exe', 'nvbackend.exe',
		'dsaservice.exe', 'dsatray.exe', 'esrv_svc.exe', 'esrv.exe',
		'igfxem.exe', 'igfxcuiservice.exe', 'igfxext.exe', 'ipfsvc.exe',
		'intelcphecisvc.exe', 'intelaudioservice.exe',
		'hp-one-agent-service.exe', 'hpmedianetwork.exe', 'sysinfocap.exe',
		'touchpointanalyticsclientservice.exe', 'omencommandcenterbackground.exe',
		'lightstudio-background.exe', 'hpprintscandoctorservice.exe',
		'hpcommrecovery.exe', 'apphelpercap.exe', 'bridgecommunication.exe',
		'rtkauduservice64.exe', 'ravbg64.exe', 'realtekaudiocontrol.exe',
		'synapticspointingdevicehelper.exe', 'etdservice.exe',
		'cnmnsst2.exe', 'cnqmmain.exe', 'nasnavi.exe', 'nassvc.exe',
		'intelgraphicssoftware.exe', 'intelgraphicssoftware.overlay.exe',
		'dsaupdateservice.exe', 'systemoptimizer.exe', 'cowork-svc.exe'
	)
}

$script:OtherCategory = 'その他'

# 名前から引く逆引き表を組み立てる
$script:ProcCategory = @{}
foreach ($cat in $script:CategoryMembers.Keys) {
	foreach ($n in $script:CategoryMembers[$cat]) {
		$script:ProcCategory[$n] = $cat
	}
}

# 辞書に無いものを拾うためのパターン。名前の一部に含まれていれば当てる
$script:CategoryPatterns = @(
	@('セキュリティ', @('mcafee', 'norton', 'avast', 'avg', 'kaspersky', 'eset', 'trendmicro',
		'sophos', 'malwarebytes', 'defender', 'mfe', 'mcshield', 'mmsshost',
		'protectedmodulehost', 'modulecoreservice')),
	@('ブラウザ',     @('chromium')),
	@('開発ツール',   @('jetbrains', 'idea64', 'pycharm', 'webstorm', 'rider64', 'gradle')),
	@('クラウドストレージ', @('dropbox', 'googledrive', 'onedrive')),
	# メーカー名は短い語で当てると誤爆する（'hp' は 'php.exe' に当たる）。
	# 区切り記号まで含めた形か、製品名として十分に長い語だけを並べる
	@('メーカー製ユーティリティ', @('nvidia', 'nvdisplay', 'realtek', 'synaptics',
		'hp-', 'hpqe', 'hpsvc', 'omen', 'touchpoint', 'intel(r)', 'intelgraphics'))
)

$script:WindowsDir = $env:SystemRoot

function Get-ProcCategory([string]$Name, [string]$Path) {
	$key = $Name.ToLower()
	if ($script:ProcCategory.ContainsKey($key)) {
		return $script:ProcCategory[$key]
	}

	foreach ($entry in $script:CategoryPatterns) {
		foreach ($pat in $entry[1]) {
			if ($key.Contains($pat)) { return $entry[0] }
		}
	}

	# 辞書にもパターンにも無いが Windows フォルダ配下にあるものは OS の一部とみなす
	if ($Path -and $script:WindowsDir -and $Path.StartsWith($script:WindowsDir, [System.StringComparison]::OrdinalIgnoreCase)) {
		return 'Windows 本体'
	}

	return $script:OtherCategory
}

# 集計と表示の順序。「その他」は必ず末尾に置く
function Get-CategoryOrder {
	$order = New-Object System.Collections.ArrayList
	foreach ($cat in $script:CategoryMembers.Keys) { [void]$order.Add($cat) }
	[void]$order.Add($script:OtherCategory)
	return @($order.ToArray())
}

# Chromium 系（Chrome・Edge・Electron アプリ）の --type= を日本語にする
$script:ChromiumTypes = @{
	'renderer'         = 'タブの描画'
	'gpu-process'      = 'GPU 処理'
	'utility'          = 'ユーティリティ処理'
	'crashpad-handler' = 'クラッシュ情報の収集'
	'zygote'           = 'プロセス生成の元'
	'broker'           = '権限の仲介'
	'ppapi'            = 'プラグイン'
	'extension'        = '拡張機能'
	'gpu'              = 'GPU 処理'
	'network'          = 'ネットワーク処理'
	'audio'            = '音声処理'
	'storage'          = 'ストレージ処理'
}

# コマンドラインを引用符を考慮してトークンに分ける
function Split-CommandLine([string]$Line) {
	if ([string]::IsNullOrEmpty($Line)) { return @() }
	$tokens = New-Object System.Collections.ArrayList
	$cur = New-Object System.Text.StringBuilder
	$inQuote = $false
	foreach ($ch in $Line.ToCharArray()) {
		if ($ch -eq '"') { $inQuote = -not $inQuote; continue }
		if ((-not $inQuote) -and ($ch -eq ' ' -or $ch -eq "`t")) {
			if ($cur.Length -gt 0) {
				[void]$tokens.Add($cur.ToString())
				[void]$cur.Clear()
			}
			continue
		}
		[void]$cur.Append($ch)
	}
	if ($cur.Length -gt 0) { [void]$tokens.Add($cur.ToString()) }
	return @($tokens.ToArray())
}

# スクリプトや jar など「実際に動かしている対象」を引数から拾う
$script:TargetExt = @('.ps1', '.psm1', '.js', '.mjs', '.cjs', '.ts', '.py', '.rb',
	'.jar', '.bat', '.cmd', '.sql', '.php', '.pl', '.lua', '.wsf', '.vbs')

function Get-RunTarget([string]$Line) {
	$tokens = Split-CommandLine $Line
	if ($tokens.Count -le 1) { return '' }
	for ($i = 1; $i -lt $tokens.Count; $i++) {
		$t = $tokens[$i]
		if ($t.StartsWith('-') -or $t.StartsWith('/')) { continue }
		$ext = ''
		try { $ext = [System.IO.Path]::GetExtension($t).ToLower() } catch { $ext = '' }
		if ($script:TargetExt -contains $ext) {
			try { return [System.IO.Path]::GetFileName($t) } catch { return $t }
		}
	}
	return ''
}

function Get-RunNote($Row) {
	$key = $Row.Name.ToLower()
	$base = ''
	if ($script:ProcNotes.ContainsKey($key)) {
		$base = $script:ProcNotes[$key]
	} elseif ($Row.Desc) {
		$base = $Row.Desc
	} else {
		$base = '不明'
	}

	$extras = New-Object System.Collections.ArrayList

	# ホストしているサービス（svchost・dllhost など）
	if ($Row.Services -and $Row.Services.Count -gt 0) {
		$names = @($Row.Services)
		if ($names.Count -le 3) {
			[void]$extras.Add('サービス: ' + ($names -join '、'))
		} else {
			[void]$extras.Add('サービス: ' + (($names | Select-Object -First 3) -join '、') + ' 他 ' + ($names.Count - 3) + ' 件')
		}
	}

	if ($Row.Cmd) {
		# Chromium 系の役割
		$m = [regex]::Match($Row.Cmd, '--type=([A-Za-z0-9\-]+)')
		if ($m.Success) {
			$t = $m.Groups[1].Value.ToLower()
			if ($script:ChromiumTypes.ContainsKey($t)) {
				[void]$extras.Add('役割: ' + $script:ChromiumTypes[$t])
			} else {
				[void]$extras.Add('役割: ' + $m.Groups[1].Value)
			}
		}

		# svchost のサービス グループ
		$m2 = [regex]::Match($Row.Cmd, '\s-k\s+([A-Za-z0-9_\-]+)')
		if ($m2.Success -and $Row.Services.Count -eq 0) {
			[void]$extras.Add('グループ: ' + $m2.Groups[1].Value)
		}

		# スクリプト・jar など
		$target = Get-RunTarget $Row.Cmd
		if ($target) {
			[void]$extras.Add('実行対象: ' + $target)
		}
	}

	if ($extras.Count -gt 0) {
		return $base + '（' + ($extras -join '／') + '）'
	}
	return $base
}

# ==================================================================
# SVG グラフ
# ==================================================================

# 横棒グラフ。Items は Label / Value / Note を持つ配列。値は多い順に並んでいる前提
function New-BarChartSvg {
	param(
		$Items,
		[string]$IdPrefix,
		[double]$MaxValue,
		[string]$Unit = ' MB',
		[int]$LabelWidth = 250,
		[double]$HueStart = 280,
		[double]$HueEnd = 0
	)

	$arr = @($Items)
	$n = $arr.Count
	if ($n -eq 0) { return '' }
	if ($MaxValue -le 0) { $MaxValue = 1 }

	$width = 1140
	$rowH = 22
	$gap = 6
	$top = 40
	$bottom = 16
	$valueWidth = 120
	$barX = $LabelWidth + 12
	$barW = $width - $barX - $valueWidth - 12
	$height = $top + $n * ($rowH + $gap) + $bottom

	$svg = New-Object System.Text.StringBuilder
	[void]$svg.AppendLine('<svg viewBox="0 0 ' + $width + ' ' + $height + '" role="img" style="max-width:100%;height:auto;display:block;" xmlns="http://www.w3.org/2000/svg">')
	[void]$svg.AppendLine('<rect width="100%" height="100%" fill="#ffffff"/>')

	# 各バーのグラデーション（下が濃く、上が明るい）
	[void]$svg.AppendLine('<defs>')
	for ($i = 0; $i -lt $n; $i++) {
		$hue = $HueStart
		if ($n -gt 1) { $hue = $HueStart - ($HueStart - $HueEnd) * $i / ($n - 1) }
		$c1 = 'hsl(' + ('{0:N0}' -f $hue) + ',78%,25%)'
		$c2 = 'hsl(' + ('{0:N0}' -f $hue) + ',58%,55%)'
		[void]$svg.AppendLine('<linearGradient id="' + $IdPrefix + '-b' + $i + '" x1="0" y1="1" x2="0" y2="0">' +
			'<stop offset="0" stop-color="' + $c1 + '"/><stop offset="1" stop-color="' + $c2 + '"/></linearGradient>')
	}
	[void]$svg.AppendLine('</defs>')

	# 目盛り（0 / 25 / 50 / 75 / 100%）
	for ($k = 0; $k -le 4; $k++) {
		$gx = $barX + $barW * $k / 4
		$gv = $MaxValue * $k / 4
		[void]$svg.AppendLine('<line x1="' + (Format-Coord $gx) + '" y1="' + ($top - 6) + '" x2="' + (Format-Coord $gx) + '" y2="' + ($height - $bottom + 2) + '" stroke="#d9dfe8" stroke-width="1"/>')
		[void]$svg.AppendLine('<text x="' + (Format-Coord $gx) + '" y="' + ($top - 14) + '" text-anchor="middle" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="12" fill="#4a5568">' + ('{0:N0}' -f $gv) + '</text>')
	}
	[void]$svg.AppendLine('<text x="' + $LabelWidth + '" y="' + ($top - 14) + '" text-anchor="end" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="12" fill="#4a5568">' + (ConvertTo-HtmlText $Unit.Trim()) + '</text>')

	for ($i = 0; $i -lt $n; $i++) {
		$it = $arr[$i]
		$y = $top + $i * ($rowH + $gap)
		$w = $barW * ([double]$it.Value / $MaxValue)
		if ($w -lt 1) { $w = 1 }

		$label = [string]$it.Label
		if ($label.Length -gt 30) { $label = $label.Substring(0, 29) + '…' }

		[void]$svg.AppendLine('<text x="' + $LabelWidth + '" y="' + ($y + 16) + '" text-anchor="end" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="13" fill="#1c2330">' + (ConvertTo-HtmlText $label) + '</text>')
		[void]$svg.AppendLine('<rect x="' + $barX + '" y="' + $y + '" width="' + (Format-Coord $w) + '" height="' + $rowH + '" rx="3" fill="url(#' + $IdPrefix + '-b' + $i + ')">' +
			'<title>' + (ConvertTo-HtmlText ([string]$it.Note)) + '</title></rect>')
		[void]$svg.AppendLine('<text x="' + (Format-Coord ($barX + $w + 8)) + '" y="' + ($y + 16) + '" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="13" fill="#1c2330">' + ('{0:N1}' -f [double]$it.Value) + '</text>')
	}

	[void]$svg.AppendLine('</svg>')
	return $svg.ToString()
}

# 物理メモリの使用状況を示す積み上げの帯
function New-MemoryBandSvg {
	param(
		[double]$UsedBytes,
		[double]$FreeBytes,
		[string]$IdPrefix
	)

	$total = $UsedBytes + $FreeBytes
	if ($total -le 0) { return '' }

	$width = 1140
	$bandY = 26
	$bandH = 52
	$height = 132
	$usedW = $width * ($UsedBytes / $total)
	$freeW = $width - $usedW

	$svg = New-Object System.Text.StringBuilder
	[void]$svg.AppendLine('<svg viewBox="0 0 ' + $width + ' ' + $height + '" role="img" style="max-width:100%;height:auto;display:block;" xmlns="http://www.w3.org/2000/svg">')
	[void]$svg.AppendLine('<rect width="100%" height="100%" fill="#ffffff"/>')
	[void]$svg.AppendLine('<defs>')
	[void]$svg.AppendLine('<linearGradient id="' + $IdPrefix + '-used" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="hsl(0,78%,25%)"/><stop offset="1" stop-color="hsl(0,58%,55%)"/></linearGradient>')
	[void]$svg.AppendLine('<linearGradient id="' + $IdPrefix + '-free" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="hsl(140,78%,25%)"/><stop offset="1" stop-color="hsl(140,58%,55%)"/></linearGradient>')
	[void]$svg.AppendLine('</defs>')

	[void]$svg.AppendLine('<text x="0" y="16" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="13" fill="#4a5568">物理メモリ 合計 ' + (Format-MB $total) + ' MB</text>')
	[void]$svg.AppendLine('<rect x="0" y="' + $bandY + '" width="' + (Format-Coord $usedW) + '" height="' + $bandH + '" fill="url(#' + $IdPrefix + '-used)"/>')
	[void]$svg.AppendLine('<rect x="' + (Format-Coord $usedW) + '" y="' + $bandY + '" width="' + (Format-Coord $freeW) + '" height="' + $bandH + '" fill="url(#' + $IdPrefix + '-free)"/>')

	$usedPct = $UsedBytes / $total * 100
	$freePct = 100 - $usedPct
	if ($usedW -gt 200) {
		[void]$svg.AppendLine('<text x="14" y="' + ($bandY + 32) + '" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="15" font-weight="700" fill="#ffffff">使用中 ' + (Format-MB $UsedBytes) + ' MB（' + (Format-Pct $usedPct) + '%）</text>')
	}
	if ($freeW -gt 200) {
		[void]$svg.AppendLine('<text x="' + (Format-Coord ($usedW + 14)) + '" y="' + ($bandY + 32) + '" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="15" font-weight="700" fill="#ffffff">空き ' + (Format-MB $FreeBytes) + ' MB（' + (Format-Pct $freePct) + '%）</text>')
	}

	# 凡例
	[void]$svg.AppendLine('<rect x="0" y="' + ($bandY + $bandH + 18) + '" width="16" height="16" rx="3" fill="url(#' + $IdPrefix + '-used)"/>')
	[void]$svg.AppendLine('<text x="24" y="' + ($bandY + $bandH + 31) + '" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="13" fill="#1c2330">使用中（赤）' + (Format-MB $UsedBytes) + ' MB</text>')
	[void]$svg.AppendLine('<rect x="260" y="' + ($bandY + $bandH + 18) + '" width="16" height="16" rx="3" fill="url(#' + $IdPrefix + '-free)"/>')
	[void]$svg.AppendLine('<text x="284" y="' + ($bandY + $bandH + 31) + '" font-family="Yu Gothic UI, Meiryo, sans-serif" font-size="13" fill="#1c2330">空き（緑）' + (Format-MB $FreeBytes) + ' MB</text>')
	[void]$svg.AppendLine('</svg>')
	return $svg.ToString()
}

# ==================================================================
# 出力先の決定
# ==================================================================

$now = Get-Date

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) {
	$OutDir = Join-Path $scriptDir '../../logs'
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

# 日付で階層に分ける（logs/yyyy/yyyymm/yyyymmdd/）。
# 1 日に何度も実行しても 1 つのフォルダが膨らまないようにする
$dayDir = [System.IO.Path]::GetFullPath((Join-Path $OutDir ($now.ToString('yyyy') + '/' + $now.ToString('yyyyMM') + '/' + $now.ToString('yyyyMMdd'))))
if (-not (Test-Path -LiteralPath $dayDir)) {
	New-Item -ItemType Directory -Path $dayDir -Force | Out-Null
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 権限をファイル名に入れる。管理者と非管理者では取れる情報が違うため、
# 前回との比較は同じ権限どうしで行う必要がある
$roleTag = 'user'
if ($isAdmin) { $roleTag = 'admin' }

$outFile = Join-Path $dayDir ($now.ToString('yyyyMMdd-HHmmss') + '-mem-' + $roleTag + '-log.html')

# 管理者でなければ自分を昇格して起動し直す。
# subst ドライブは昇格先から見えないため、自分のパスを実体へ直してから渡す
if ((-not $isAdmin) -and (-not $NoElevate)) {
	$selfPath = Resolve-SubstPath $MyInvocation.MyCommand.Path
	$q = [char]34
	$argLine = '-NoProfile -ExecutionPolicy Bypass -File ' + $q + $selfPath + $q + ' -NoElevate -Pause'
	if ($Open) { $argLine += ' -Open' }
	if ($TopCount -ne 30) { $argLine += ' -TopCount ' + $TopCount }
	if ($script:FoundSubstDrive) {
		$argLine += ' -SubstDrive ' + $script:FoundSubstDrive + ' -SubstRoot ' + $q + $script:FoundSubstRoot + $q
	}

	Write-Host '管理者権限で起動し直します...'
	try {
		Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList $argLine -ErrorAction Stop
		exit 0
	} catch {
		Write-Host '  昇格が取り消されました。このまま非管理者で続行します。' -ForegroundColor Yellow
	}
}

Write-Host 'プロセス情報を収集しています...'
if (-not $isAdmin) {
	Write-Host '  ※ 管理者権限で実行していません。コマンドラインの一部が取得できません。' -ForegroundColor Yellow
}

# ==================================================================
# 収集
# ==================================================================

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$totalBytes = [double]$os.TotalVisibleMemorySize * 1KB
$freeBytes = [double]$os.FreePhysicalMemory * 1KB
$usedBytes = $totalBytes - $freeBytes
$bootTime = $os.LastBootUpTime

# Get-Process は説明・会社名（FileVersionInfo）を取るためだけに使う
$psMap = @{}
foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
	$psMap[[int]$p.Id] = $p
}

# PID からホストしているサービスの表示名を引く
$svcMap = @{}
foreach ($s in (Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
	if ($s.ProcessId -and [int]$s.ProcessId -gt 0) {
		$sid = [int]$s.ProcessId
		if (-not $svcMap.ContainsKey($sid)) {
			$svcMap[$sid] = New-Object System.Collections.ArrayList
		}
		$dn = [string]$s.DisplayName
		if (-not $dn) { $dn = [string]$s.Name }
		[void]$svcMap[$sid].Add($dn)
	}
}

$cimProcs = Get-CimInstance -ClassName Win32_Process

$rows = New-Object System.Collections.ArrayList
$noStartCount = 0
$noCmdCount = 0

foreach ($c in $cimProcs) {
	$id = [int]$c.ProcessId

	$start = $null
	if ($c.CreationDate) { $start = [datetime]$c.CreationDate } else { $noStartCount++ }

	$uptime = $null
	if ($start) { $uptime = $now - $start }

	$cmd = [string]$c.CommandLine
	if ([string]::IsNullOrEmpty($cmd)) { $noCmdCount++ }

	$desc = ''
	if ($psMap.ContainsKey($id)) {
		try { $desc = [string]$psMap[$id].Description } catch { $desc = '' }
	}

	# CPU 時間は 100ns 単位。Get-Process の .CPU はアクセス拒否で欠けることがある
	$cpuSec = 0.0
	if ($null -ne $c.UserModeTime -and $null -ne $c.KernelModeTime) {
		$cpuSec = ([double]$c.UserModeTime + [double]$c.KernelModeTime) / 10000000.0
	}

	$services = @()
	if ($svcMap.ContainsKey($id)) { $services = @($svcMap[$id]) }

	$row = [PSCustomObject]@{
		Id       = $id
		ParentId = [int]$c.ParentProcessId
		Name     = [string]$c.Name
		Ws       = [double]$c.WorkingSetSize
		Priv     = $(if ($null -ne $c.PrivatePageCount) { [double]$c.PrivatePageCount } else { 0.0 })
		Virt     = $(if ($null -ne $c.VirtualSize) { [double]$c.VirtualSize } else { 0.0 })
		Threads  = [int]$c.ThreadCount
		Handles  = [int]$c.HandleCount
		CpuSec   = $cpuSec
		Start    = $start
		Uptime   = $uptime
		Path     = Hide-Private ([string]$c.ExecutablePath)
		Cmd      = Hide-Private $cmd
		Desc     = Hide-Private $desc
		Services = $services
		Category = Get-ProcCategory ([string]$c.Name) ([string]$c.ExecutablePath)
		Note     = ''
	}
	$row.Note = Get-RunNote $row
	[void]$rows.Add($row)
}

$procCount = $rows.Count
$wsTotal = 0.0
foreach ($r in $rows) { $wsTotal += $r.Ws }

$byWs = @($rows | Sort-Object -Property Ws -Descending)
$byStart = @($rows | Sort-Object -Property @{ Expression = { if ($_.Start) { $_.Start } else { [datetime]'9999-12-31' } } })
$wsMax = 1.0
if ($byWs.Count -gt 0) { $wsMax = [double]$byWs[0].Ws }
if ($wsMax -le 0) { $wsMax = 1.0 }

# プロセス名ごとの集計
$byName = @($rows | Group-Object -Property Name | ForEach-Object {
	$g = $_.Group
	$sum = 0.0
	$oldest = $null
	foreach ($x in $g) {
		$sum += $x.Ws
		if ($x.Start -and ((-not $oldest) -or $x.Start -lt $oldest)) { $oldest = $x.Start }
	}
	$key = ([string]$_.Name).ToLower()
	$note = ''
	if ($script:ProcNotes.ContainsKey($key)) {
		$note = $script:ProcNotes[$key]
	} else {
		$note = [string]($g | Where-Object { $_.Desc } | Select-Object -First 1 -ExpandProperty Desc)
		if (-not $note) { $note = '不明' }
	}
	[PSCustomObject]@{
		Name   = $_.Name
		Count  = $g.Count
		WsSum  = $sum
		Oldest = $oldest
		Note   = $note
	}
} | Sort-Object -Property WsSum -Descending)

$nameMax = 1.0
if ($byName.Count -gt 0) { $nameMax = [double]$byName[0].WsSum }
if ($nameMax -le 0) { $nameMax = 1.0 }

# カテゴリごとの集計。件数 0 のカテゴリも並びを保つため落とさない
$byCategory = New-Object System.Collections.ArrayList
foreach ($cat in (Get-CategoryOrder)) {
	$g = @($rows | Where-Object { $_.Category -eq $cat })
	$sum = 0.0
	foreach ($x in $g) { $sum += $x.Ws }
	[void]$byCategory.Add([PSCustomObject]@{
		Name  = $cat
		Count = $g.Count
		WsSum = $sum
		Pct   = $(if ($wsTotal -gt 0) { $sum / $wsTotal * 100 } else { 0.0 })
	})
}
$byCategory = @($byCategory.ToArray())

# 分類漏れがあれば総計と合わなくなる。気づけるようにその場で照合する
$catTotal = 0.0
$catCount = 0
foreach ($c in $byCategory) { $catTotal += $c.WsSum; $catCount += $c.Count }

# 親子関係。PID は再利用されるため、親の起動が子より後なら親とみなさない
$rowMap = @{}
foreach ($r in $rows) { $rowMap[$r.Id] = $r }

$script:childMap = @{}
$roots = New-Object System.Collections.ArrayList
foreach ($r in $rows) {
	$parent = $null
	if ($r.ParentId -gt 0 -and $r.ParentId -ne $r.Id -and $rowMap.ContainsKey($r.ParentId)) {
		$parent = $rowMap[$r.ParentId]
		if ($parent.Start -and $r.Start -and $parent.Start -gt $r.Start) { $parent = $null }
	}
	if ($null -eq $parent) {
		[void]$roots.Add($r)
	} else {
		if (-not $script:childMap.ContainsKey($parent.Id)) {
			$script:childMap[$parent.Id] = New-Object System.Collections.ArrayList
		}
		[void]$script:childMap[$parent.Id].Add($r)
	}
}

Write-Host ('  プロセス ' + $procCount + ' 件を取得しました。')

Write-Host '  カテゴリ別:'
foreach ($c in $byCategory) {
	Write-Host ('    {0,-14} {1,4} 件  {2,10} MB  ({3,5:N1} %)' -f $c.Name, $c.Count, (Format-MB $c.WsSum), $c.Pct)
}
if ($catCount -ne $procCount) {
	Write-Host ('  ※ カテゴリの件数合計 {0} が総数 {1} と一致しません。' -f $catCount, $procCount) -ForegroundColor Red
}
if ([Math]::Abs($catTotal - $wsTotal) -gt 1) {
	Write-Host ('  ※ カテゴリのメモリ合計 {0} が総計 {1} と一致しません。' -f (Format-MB $catTotal), (Format-MB $wsTotal)) -ForegroundColor Red
}

# 「その他」に落ちたものを名前ごとにまとめて出す。分類辞書を足す手掛かりになる
$other = @($rows | Where-Object { $_.Category -eq $script:OtherCategory })
if ($other.Count -gt 0) {
	Write-Host '  「その他」の内訳（メモリの多い順・上位 15 種類）:'
	$otherByName = @($other | Group-Object -Property Name | ForEach-Object {
		$sum = 0.0
		foreach ($x in $_.Group) { $sum += $x.Ws }
		[PSCustomObject]@{ Name = $_.Name; Count = $_.Group.Count; WsSum = $sum }
	} | Sort-Object -Property WsSum -Descending)
	foreach ($o in ($otherByName | Select-Object -First 15)) {
		Write-Host ('    {0,-34} {1,3} 件  {2,9} MB' -f $o.Name, $o.Count, (Format-MB $o.WsSum))
	}
	Write-Host ('    （全 {0} 種類 / {1} 件）' -f $otherByName.Count, $other.Count)
}

# ==================================================================
# HTML の組み立て
# ==================================================================

$dateStr = $now.ToString('yyyy-MM-dd')
$stampStr = $now.ToString('yyyy-MM-dd HH:mm:ss')

$css = @'
	:root{
		--navy1:#12224d; --navy2:#2f5fbf;
		--ink:#1c2330; --ink-soft:#4a5568; --line:#d9dfe8; --code-bg:#f4f6fa;
		--link:#1a4fa0;
		--accent:#12224d; --accent2:#2f5fbf; --soft:#f2f5fb;
	}
	.ch01{--accent:hsl(280,78%,25%);--accent2:hsl(280,58%,55%);--soft:hsl(280,28%,95%);}
	.ch02{--accent:hsl(210,78%,25%);--accent2:hsl(210,58%,55%);--soft:hsl(210,28%,95%);}
	.ch03{--accent:hsl(140,78%,25%);--accent2:hsl(140,58%,55%);--soft:hsl(140,28%,95%);}
	.ch04{--accent:hsl(70,78%,25%);--accent2:hsl(70,58%,55%);--soft:hsl(70,28%,95%);}
	.ch05{--accent:hsl(0,78%,25%);--accent2:hsl(0,58%,55%);--soft:hsl(0,28%,95%);}

	*{box-sizing:border-box;}
	body{margin:0;background:#fff;color:#1c2330;
		font-family:"Yu Gothic UI","Meiryo","Segoe UI",system-ui,sans-serif;
		font-size:15.5px;line-height:1.85;}

	.titlebar{background:linear-gradient(135deg,var(--navy1,#12224d),var(--navy2,#2f5fbf));color:#fff;padding:34px 30px 30px;}
	.titlebar .inner{max-width:1600px;margin:0 auto;}
	.titlebar h1{font-size:1.9em;margin:0 0 8px;color:#fff;}
	.titlebar .lead{font-size:.92em;color:#dde6f7;background:transparent;}
	.titlebar .date{font-size:.88em;color:#c9d8f2;background:transparent;margin-top:6px;}

	.wrap{max-width:1600px;margin:0 auto;padding:0 30px;}

	a{color:var(--link,#1a4fa0);background:transparent;}

	.toc{margin:26px 0 0;}
	.toc ol{list-style:none;display:flex;flex-wrap:wrap;gap:8px;padding:0;margin:12px 0 0;counter-reset:tocn;}
	.toc li{counter-increment:tocn;}
	.toc a{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;
		text-overflow:ellipsis;white-space:normal;width:310px;max-width:100%;
		background:linear-gradient(100deg,var(--accent,#12224d),var(--accent2,#2f5fbf));
		color:#fff;text-decoration:none;padding:8px 12px;border-radius:8px;font-weight:700;font-size:.92em;}
	.toc a::before{content:counter(tocn) ". ";font-weight:700;}

	section{background:linear-gradient(180deg,var(--soft,#f2f5fb),#fff);color:var(--ink,#1c2330);
		border:1px solid var(--line,#d9dfe8);border-radius:10px;padding:4px 26px 26px;margin:34px 0;}
	section h1{background:linear-gradient(100deg,var(--accent,#12224d),var(--accent2,#2f5fbf));
		color:#fff;padding:14px 20px;margin:26px 0 20px;border-radius:8px;
		box-shadow:0 3px 10px rgba(18,34,77,.22);font-size:1.4em;}
	h2{background:linear-gradient(90deg,var(--soft,#f2f5fb),#fff);color:var(--accent,#12224d);
		border-left:6px solid var(--accent,#12224d);padding:6px 12px;margin:30px 0 12px;
		font-size:1.12em;border-radius:0 6px 6px 0;}
	h3{display:inline-block;color:var(--accent,#12224d);background:transparent;
		border-bottom:2px dotted var(--accent2,#2f5fbf);padding-bottom:3px;margin:20px 0 8px;font-size:1em;}
	p{background:transparent;color:var(--ink,#1c2330);}

	.figure{background:#fff;color:var(--ink,#1c2330);border:1px solid var(--line,#d9dfe8);
		border-radius:8px;padding:14px 16px;margin:12px 0 18px;overflow-x:auto;
		box-shadow:0 2px 6px rgba(18,34,77,.08);}

	.tablewrap{overflow-x:auto;margin:2px 0;}
	table{border-collapse:collapse;width:100%;background:#fff;color:var(--ink,#1c2330);
		border-radius:8px;overflow:hidden;box-shadow:0 2px 6px rgba(18,34,77,.10);font-size:.9em;
		line-height:1.3;}
	th{background:linear-gradient(100deg,var(--accent,#12224d),var(--accent2,#2f5fbf));
		color:#fff;padding:1px 10px;text-align:left;white-space:nowrap;font-weight:700;}
	td{padding:1px 10px;border-bottom:1px solid var(--line,#d9dfe8);vertical-align:top;
		background:transparent;color:var(--ink,#1c2330);}
	tr:nth-child(even) td{background:#fafbfe;color:var(--ink,#1c2330);}
	td.num{text-align:right;white-space:nowrap;}
	td.nowrap{white-space:nowrap;}
	td.note{min-width:260px;color:var(--ink,#1c2330);background:transparent;}
	tr:nth-child(even) td.note{background:#fafbfe;}
	td.path{white-space:nowrap;color:var(--ink-soft,#4a5568);background:transparent;font-size:.94em;}
	tr:nth-child(even) td.path{background:#fafbfe;}
	td.cmd{white-space:nowrap;color:var(--ink-soft,#4a5568);background:transparent;font-size:.92em;
		font-family:Consolas,"Courier New",monospace;}
	tr:nth-child(even) td.cmd{background:#fafbfe;}

	.bar{background:#e7ecf4;color:var(--ink,#1c2330);border-radius:3px;height:12px;width:140px;
		overflow:hidden;display:inline-block;vertical-align:middle;}
	.bar span{display:block;height:100%;color:#fff;
		background:linear-gradient(100deg,var(--accent,#12224d),var(--accent2,#2f5fbf));}

	.badge{display:inline-block;padding:1px 9px;border-radius:999px;font-size:.82em;font-weight:700;
		white-space:nowrap;color:#fff;background:linear-gradient(100deg,#5a6472,#97a1ae);}
	.b-ok{color:#fff;background:linear-gradient(100deg,#1d7a3c,#45b56c);}
	.b-ng{color:#fff;background:linear-gradient(100deg,#a51f22,#e05a5c);}
	.b-warn{color:#fff;background:linear-gradient(100deg,#b8620a,#f0a548);}
	.b-none{color:#fff;background:linear-gradient(100deg,#5a6472,#97a1ae);}

	.callout{border-left:6px solid var(--accent,#12224d);
		background:linear-gradient(180deg,var(--soft,#f2f5fb),#fff);color:var(--ink,#1c2330);
		border-radius:0 8px 8px 0;padding:12px 16px;margin:16px 0;}
	.callout strong{color:var(--accent,#12224d);background:transparent;}

	code{background:var(--code-bg,#f4f6fa);border:1px solid var(--line,#d9dfe8);color:#17335f;
		padding:1px 5px;border-radius:4px;font-size:.92em;
		font-family:Consolas,"Courier New",monospace;}

	details{margin:10px 0;}
	summary{cursor:pointer;font-weight:700;color:var(--accent,#12224d);background:transparent;}

	.tree{background:#fff;color:var(--ink,#1c2330);border:1px solid var(--line,#d9dfe8);
		border-radius:8px;padding:12px 16px;overflow-x:auto;font-size:.88em;}
	.tnode{white-space:nowrap;padding:1px 0;color:var(--ink,#1c2330);background:transparent;}
	.tnode .nm{color:var(--ink,#1c2330);background:transparent;font-weight:700;}
	.tnode .pid{color:var(--ink-soft,#4a5568);background:transparent;}
	.tnode .mem{color:#12224d;background:transparent;}
	.tnode .st{color:var(--ink-soft,#4a5568);background:transparent;}
	.tnode .nt{color:var(--ink-soft,#4a5568);background:transparent;}

	footer{max-width:1600px;margin:40px auto 0;padding:18px 30px 0;
		border-top:1px solid var(--line,#d9dfe8);color:var(--ink-soft,#4a5568);
		background:#fff;font-size:.88em;}
'@

Add-Html '<!DOCTYPE html>'
Add-Html '<html lang="ja">'
Add-Html '<head>'
Add-Html '<meta charset="UTF-8">'
Add-Html '<meta name="viewport" content="width=device-width, initial-scale=1">'
Add-Html '<meta name="md-skip">'
Add-Html ('<title>プロセスメモリ調査 ' + (ConvertTo-HtmlText $stampStr) + '</title>')
Add-Html '<style>'
Add-Html $css
Add-Html '</style>'
Add-Html '</head>'
Add-Html '<body>'

# --- タイトルバー ---
Add-Html '<div class="titlebar"><div class="inner">'
Add-Html '<h1>プロセスメモリ調査</h1>'
Add-Html ('<div class="lead">取得日時 ' + (ConvertTo-HtmlText $stampStr) + ' ／ プロセス ' + $procCount + ' 件 ／ メモリ使用量の多い順</div>')
Add-Html ('<div class="date">📅 作成: ' + $dateStr + ' / 更新: ' + $dateStr + '</div>')
Add-Html '</div></div>'

Add-Html '<div class="wrap">'

# --- 目次 ---
Add-Html '<nav class="toc">'
Add-Html '<ol>'
Add-Html '<li class="ch01"><a href="#ch01">サマリ</a></li>'
Add-Html '<li class="ch02"><a href="#ch02">プロセス名ごとの集計</a></li>'
Add-Html '<li class="ch03"><a href="#ch03">プロセス一覧（メモリ順）</a></li>'
Add-Html '<li class="ch04"><a href="#ch04">起動時刻順（古い順）</a></li>'
Add-Html '<li class="ch05"><a href="#ch05">プロセスツリー</a></li>'
Add-Html '</ol>'
Add-Html '</nav>'

# ==================================================================
# 1. サマリ
# ==================================================================
Add-Html '<section class="ch01" id="ch01">'
Add-Html '<h1>サマリ</h1>'

$usedPct = 0.0
if ($totalBytes -gt 0) { $usedPct = $usedBytes / $totalBytes * 100 }

$sysUptime = $null
if ($bootTime) { $sysUptime = $now - [datetime]$bootTime }

Add-Html '<h2>物理メモリの使用状況</h2>'
Add-Html '<div class="figure">'
Add-Html (New-MemoryBandSvg -UsedBytes $usedBytes -FreeBytes $freeBytes -IdPrefix 'g-01-1')
Add-Html '</div>'

Add-Html '<h2>システム</h2>'
Add-Html '<div class="tablewrap"><table>'
Add-Html '<thead><tr><th>項目</th><th>値</th></tr></thead><tbody>'
Add-Html ('<tr><td class="nowrap">取得日時</td><td class="nowrap">' + (ConvertTo-HtmlText $stampStr) + '</td></tr>')
Add-Html ('<tr><td class="nowrap">OS</td><td>' + (ConvertTo-HtmlText (Hide-Private ([string]$os.Caption + ' (' + [string]$os.Version + ')'))) + '</td></tr>')
if ($bootTime) {
	Add-Html ('<tr><td class="nowrap">システム起動時刻</td><td class="nowrap">' + ([datetime]$bootTime).ToString('yyyy-MM-dd HH:mm:ss') + '　（稼働 ' + (Format-Span $sysUptime) + '）</td></tr>')
}
Add-Html ('<tr><td class="nowrap">物理メモリ 総量</td><td class="nowrap">' + (Format-MB $totalBytes) + ' MB</td></tr>')
Add-Html ('<tr><td class="nowrap">物理メモリ 使用中</td><td class="nowrap">' + (Format-MB $usedBytes) + ' MB（' + (Format-Pct $usedPct) + ' %）</td></tr>')
Add-Html ('<tr><td class="nowrap">物理メモリ 空き</td><td class="nowrap">' + (Format-MB $freeBytes) + ' MB</td></tr>')
Add-Html '</tbody></table></div>'

Add-Html '<h2>プロセス</h2>'
Add-Html '<div class="tablewrap"><table>'
Add-Html '<thead><tr><th>項目</th><th>値</th></tr></thead><tbody>'
Add-Html ('<tr><td class="nowrap">プロセス数</td><td class="nowrap">' + $procCount + ' 件（実行ファイル ' + $byName.Count + ' 種類）</td></tr>')
Add-Html ('<tr><td class="nowrap">ワーキングセット合計</td><td class="nowrap">' + (Format-MB $wsTotal) + ' MB</td></tr>')

$adminBadge = '<span class="badge b-warn">非管理者</span>'
if ($isAdmin) { $adminBadge = '<span class="badge b-ok">管理者</span>' }
Add-Html ('<tr><td class="nowrap">実行権限</td><td class="nowrap">' + $adminBadge + '</td></tr>')

$startBadge = '<span class="badge b-warn">' + $noStartCount + ' 件 取得不可</span>'
if ($noStartCount -eq 0) { $startBadge = '<span class="badge b-ok">全件取得</span>' }
Add-Html ('<tr><td class="nowrap">起動時刻</td><td class="nowrap">' + $startBadge + '</td></tr>')

$cmdBadge = '<span class="badge b-warn">' + $noCmdCount + ' 件 取得不可</span>'
if ($noCmdCount -eq 0) { $cmdBadge = '<span class="badge b-ok">全件取得</span>' }
Add-Html ('<tr><td class="nowrap">コマンドライン</td><td class="nowrap">' + $cmdBadge + '</td></tr>')
Add-Html '</tbody></table></div>'

Add-Html ('<h2>メモリ使用量 上位 ' + $TopCount + ' 件</h2>')
Add-Html '<div class="figure">'
$topItems = @($byWs | Select-Object -First $TopCount | ForEach-Object {
	[PSCustomObject]@{
		Label = $_.Name + ' #' + $_.Id
		Value = $_.Ws / 1MB
		Note  = $_.Note
	}
})
Add-Html (New-BarChartSvg -Items $topItems -IdPrefix 'g-01-2' -MaxValue ($wsMax / 1MB) -Unit 'MB' -LabelWidth 260)
Add-Html '</div>'
Add-Html '<p>バーにマウスを合わせると、そのプロセスが何を実行しているのかを表示する。</p>'

if (-not $isAdmin) {
	Add-Html '<div class="callout"><strong>管理者権限で実行していません。</strong>他ユーザーおよび昇格プロセスのコマンドラインが空欄になり、実行内容の補足も薄くなります。完全な情報が必要な場合は同じフォルダの cmd ランチャーから起動してください。</div>'
}

Add-Html '</section>'

# ==================================================================
# 2. プロセス名ごとの集計
# ==================================================================
Add-Html '<section class="ch02" id="ch02">'
Add-Html '<h1>プロセス名ごとの集計</h1>'
Add-Html '<p>同名のプロセスをまとめ、物理メモリの合計が多い順に並べる。chrome や svchost のように多数起動するものは、ここで実際の占有量が分かる。</p>'

Add-Html ('<h2>合計メモリ 上位 ' + $TopCount + ' 種類</h2>')
Add-Html '<div class="figure">'
$nameItems = @($byName | Select-Object -First $TopCount | ForEach-Object {
	[PSCustomObject]@{
		Label = $_.Name + '（' + $_.Count + '）'
		Value = $_.WsSum / 1MB
		Note  = $_.Note
	}
})
Add-Html (New-BarChartSvg -Items $nameItems -IdPrefix 'g-02-1' -MaxValue ($nameMax / 1MB) -Unit 'MB' -LabelWidth 260)
Add-Html '</div>'

Add-Html '<h2>全一覧</h2>'
Add-Html '<div class="tablewrap"><table>'
Add-Html '<thead><tr><th>#</th><th>プロセス名</th><th>実行内容</th><th>件数</th><th>物理メモリ 合計</th><th>比率</th><th>最も古い起動</th></tr></thead><tbody>'
$rank = 0
foreach ($g in $byName) {
	$rank++
	$w = $g.WsSum / $nameMax * 100
	$oldestText = '取得不可'
	if ($g.Oldest) { $oldestText = $g.Oldest.ToString('yyyy-MM-dd HH:mm:ss') }
	Add-Html ('<tr><td class="num">' + $rank + '</td>' +
		'<td class="nowrap">' + (ConvertTo-HtmlText $g.Name) + '</td>' +
		'<td class="note">' + (ConvertTo-HtmlText $g.Note) + '</td>' +
		'<td class="num">' + $g.Count + '</td>' +
		'<td class="num">' + (Format-MB $g.WsSum) + ' MB</td>' +
		'<td class="nowrap"><span class="bar"><span style="width:' + (Format-Pct $w) + '%"></span></span></td>' +
		'<td class="nowrap">' + $oldestText + '</td></tr>')
}
Add-Html '</tbody></table></div>'
Add-Html '</section>'

# ==================================================================
# 3. プロセス一覧（メモリ順）
# ==================================================================
Add-Html '<section class="ch03" id="ch03">'
Add-Html '<h1>プロセス一覧（メモリ順）</h1>'
Add-Html ('<p>全 ' + $procCount + ' 件を物理メモリ（ワーキングセット）の多い順に並べる。「実行内容」は実行ファイル名の辞書・ホストしているサービス・コマンドラインの引数から組み立てている。コマンドラインは 100 文字で切り、全文はセルのツールチップに入れてある。</p>')
Add-Html '<div class="tablewrap"><table>'
Add-Html '<thead><tr><th>#</th><th>プロセス名</th><th>実行内容</th><th>PID</th><th>物理MB</th><th>比率</th><th>プライベートMB</th><th>仮想MB</th><th>スレッド</th><th>ハンドル</th><th>CPU秒</th><th>起動日時</th><th>稼働</th><th>パス</th><th>コマンドライン</th></tr></thead><tbody>'
$rank = 0
foreach ($r in $byWs) {
	$rank++
	$w = $r.Ws / $wsMax * 100
	$startText = '取得不可'
	if ($r.Start) { $startText = $r.Start.ToString('yyyy-MM-dd HH:mm:ss') }
	$cmdFull = $r.Cmd
	$cmdShort = $cmdFull
	if ([string]::IsNullOrEmpty($cmdShort)) {
		$cmdShort = '取得不可'
	} elseif ($cmdShort.Length -gt 100) {
		$cmdShort = $cmdShort.Substring(0, 100) + '…'
	}
	$pathText = $r.Path
	if ([string]::IsNullOrEmpty($pathText)) { $pathText = '取得不可' }
	Add-Html ('<tr><td class="num">' + $rank + '</td>' +
		'<td class="nowrap">' + (ConvertTo-HtmlText $r.Name) + '</td>' +
		'<td class="note">' + (ConvertTo-HtmlText $r.Note) + '</td>' +
		'<td class="num">' + $r.Id + '</td>' +
		'<td class="num">' + (Format-MB $r.Ws) + '</td>' +
		'<td class="nowrap"><span class="bar"><span style="width:' + (Format-Pct $w) + '%"></span></span></td>' +
		'<td class="num">' + (Format-MB $r.Priv) + '</td>' +
		'<td class="num">' + (Format-MB $r.Virt) + '</td>' +
		'<td class="num">' + $r.Threads + '</td>' +
		'<td class="num">' + $r.Handles + '</td>' +
		'<td class="num">' + ('{0:N1}' -f $r.CpuSec) + '</td>' +
		'<td class="nowrap">' + $startText + '</td>' +
		'<td class="nowrap">' + (Format-Span $r.Uptime) + '</td>' +
		'<td class="path" title="' + (ConvertTo-HtmlAttr $pathText) + '">' + (ConvertTo-HtmlText $pathText) + '</td>' +
		'<td class="cmd" title="' + (ConvertTo-HtmlAttr $cmdFull) + '">' + (ConvertTo-HtmlText $cmdShort) + '</td></tr>')
}
Add-Html '</tbody></table></div>'
Add-Html '</section>'

# ==================================================================
# 4. 起動時刻順
# ==================================================================
Add-Html '<section class="ch04" id="ch04">'
Add-Html '<h1>起動時刻順（古い順）</h1>'
Add-Html '<p>いつから動いているかを見るための並び。上にあるものほど長く常駐している。システム起動時刻より前のものは無い。</p>'
Add-Html '<div class="tablewrap"><table>'
Add-Html '<thead><tr><th>#</th><th>起動日時</th><th>稼働</th><th>プロセス名</th><th>実行内容</th><th>PID</th><th>物理MB</th><th>パス</th></tr></thead><tbody>'
$rank = 0
foreach ($r in $byStart) {
	$rank++
	$startText = '取得不可'
	if ($r.Start) { $startText = $r.Start.ToString('yyyy-MM-dd HH:mm:ss') }
	$pathText = $r.Path
	if ([string]::IsNullOrEmpty($pathText)) { $pathText = '取得不可' }
	Add-Html ('<tr><td class="num">' + $rank + '</td>' +
		'<td class="nowrap">' + $startText + '</td>' +
		'<td class="nowrap">' + (Format-Span $r.Uptime) + '</td>' +
		'<td class="nowrap">' + (ConvertTo-HtmlText $r.Name) + '</td>' +
		'<td class="note">' + (ConvertTo-HtmlText $r.Note) + '</td>' +
		'<td class="num">' + $r.Id + '</td>' +
		'<td class="num">' + (Format-MB $r.Ws) + '</td>' +
		'<td class="path" title="' + (ConvertTo-HtmlAttr $pathText) + '">' + (ConvertTo-HtmlText $pathText) + '</td></tr>')
}
Add-Html '</tbody></table></div>'
Add-Html '</section>'

# ==================================================================
# 5. プロセスツリー
# ==================================================================
Add-Html '<section class="ch05" id="ch05">'
Add-Html '<h1>プロセスツリー</h1>'
Add-Html '<p>親子関係で入れ子にし、同じ階層はメモリの多い順に並べる。PID は使い回されるため、親の起動時刻が子より後になる組は親子とみなしていない。</p>'
Add-Html '<details open><summary>ツリーを表示</summary>'
Add-Html '<div class="tree">'

$script:shown = @{}

function Add-TreeNode($Row, [int]$Depth) {
	if ($script:shown.ContainsKey($Row.Id)) { return }
	$script:shown[$Row.Id] = $true

	$startText = '--'
	if ($Row.Start) { $startText = $Row.Start.ToString('MM-dd HH:mm:ss') }
	$pad = $Depth * 22

	$note = [string]$Row.Note
	if ($note.Length -gt 60) { $note = $note.Substring(0, 59) + '…' }

	Add-Html ('<div class="tnode" style="padding-left:' + $pad + 'px">' +
		'<span class="nm">' + (ConvertTo-HtmlText $Row.Name) + '</span> ' +
		'<span class="pid">#' + $Row.Id + '</span> ' +
		'<span class="mem">' + (Format-MB $Row.Ws) + ' MB</span> ' +
		'<span class="st">起動 ' + $startText + '</span> ' +
		'<span class="nt">' + (ConvertTo-HtmlText $note) + '</span></div>')

	if ($Depth -ge 20) { return }
	if ($script:childMap.ContainsKey($Row.Id)) {
		foreach ($c in ($script:childMap[$Row.Id] | Sort-Object -Property Ws -Descending)) {
			Add-TreeNode $c ($Depth + 1)
		}
	}
}

foreach ($r in ($roots | Sort-Object -Property Ws -Descending)) {
	Add-TreeNode $r 0
}

# 循環参照などで木に載らなかったものを拾う
$missing = @($rows | Where-Object { -not $script:shown.ContainsKey($_.Id) })
if ($missing.Count -gt 0) {
	Add-Html '<div class="tnode" style="padding-left:0px"><span class="nm">（親子関係をたどれなかったプロセス）</span></div>'
	foreach ($r in ($missing | Sort-Object -Property Ws -Descending)) {
		Add-TreeNode $r 1
	}
}

Add-Html '</div>'
Add-Html '</details>'
Add-Html '</section>'

Add-Html '</div>'

Add-Html '<footer>'
Add-Html ('生成: ' + (ConvertTo-HtmlText $stampStr) + ' ／ inspect-process-memory.ps1 ／ Windows PowerShell ' + $PSVersionTable.PSVersion.ToString())
Add-Html '</footer>'

Add-Html '</body>'
Add-Html '</html>'

# ==================================================================
# 書き出し
# ==================================================================

# HTML は BOM 付きで書く。HTML5 は BOM を meta charset より優先するため、
# どのブラウザで開いても文字化けしない。
# 改行は LF に揃える（AppendLine は Environment.NewLine を使うため CRLF になる）
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$html = $script:sb.ToString() -replace "\r?\n", "`n"
[System.IO.File]::WriteAllText($outFile, $html, $utf8Bom)

Write-Host ('出力しました: ' + (Hide-Private $outFile))

# ==================================================================
# 出力の記録を残す
# ==================================================================

# プロジェクトルートからの相対パスで書く。フォルダごと移しても読める
$projectRoot = Split-Path -Parent $OutDir
$relPath = $outFile
if ($outFile.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
	$relPath = $outFile.Substring($projectRoot.Length).TrimStart('\', '/')
}

# 直近の 1 件。cmd がこれを読んで claude へ渡す
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'last-report.txt'), $relPath, $utf8NoBom)

# 権限ごとの履歴。末尾に追記していく。
# 前回との比較はここから取る。管理者と非管理者を混ぜると、取得できた情報の差が
# そのまま差分に出てしまうため分けて持つ
$historyPath = Join-Path $OutDir ('reports-' + $roleTag + '.txt')
[System.IO.File]::AppendAllText($historyPath, $relPath + "`n", $utf8NoBom)

Write-Host ('記録しました: ' + (Split-Path -Leaf $historyPath))

if ($Open) {
	Start-Process -FilePath $outFile
}

if ($Pause) {
	Write-Host ''
	Read-Host 'Enter キーで終了します'
}
