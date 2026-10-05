param(
    [Parameter(Mandatory = $true)][string]$ChromePath,
    [string]$ExtensionPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cdp.ps1')

function Assert-Result {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Wait-Until {
    param([scriptblock]$Check, [string]$Message)
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if (& $Check) { return }
        Start-Sleep -Milliseconds 200
    }
    throw $Message
}

function Invoke-Js {
    param($Connection, [string]$Expression)
    $response = Invoke-Cdp -Connection $Connection -Method 'Runtime.evaluate' -Params @{
        expression = $Expression
        awaitPromise = $true
        returnByValue = $true
    }
    if ($response.exceptionDetails) {
        $details = $response.exceptionDetails.exception.description
        if (-not $details) { $details = $response.exceptionDetails.text }
        throw "JavaScript exception: $details`nExpression: $Expression"
    }
    return $response.result.value
}

function Get-TargetInfos {
    param($Browser)
    return (Invoke-Cdp -Connection $Browser -Method 'Target.getTargets' -Params @{
        filter = @(@{})
    }).targetInfos
}

function Get-ExtensionErrors {
    param($Connection)
    return @($Connection.Events | Where-Object {
        $_.method -eq 'Runtime.exceptionThrown' -or
        ($_.method -eq 'Log.entryAdded' -and $_.params.entry.level -eq 'error')
    })
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ExtensionPath) { $ExtensionPath = Join-Path $repoRoot 'bookmarks-on-new-tab' }
$ChromePath = (Resolve-Path -LiteralPath $ChromePath).Path
$ExtensionPath = (Resolve-Path -LiteralPath $ExtensionPath).Path
Assert-Result (Test-Path -LiteralPath (Join-Path $ExtensionPath 'manifest.json') -PathType Leaf) `
    'The extension directory has no manifest.json'

$profilePath = Join-Path ([System.IO.Path]::GetTempPath()) (
    'bookmarks-newtab-smoke-' + [guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $profilePath)
$chrome = $null
$browser = $null
$page = $null
$options = $null
$worker = $null

try {
    $chrome = Start-Process -FilePath $ChromePath -ArgumentList @(
        '--headless=new', '--no-first-run', '--no-default-browser-check',
        "--user-data-dir=`"$profilePath`"", '--remote-debugging-port=0',
        "--disable-extensions-except=`"$ExtensionPath`"",
        "--load-extension=`"$ExtensionPath`"", 'about:blank'
    ) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $profilePath 'chrome-stderr.log')

    $portFile = Join-Path $profilePath 'DevToolsActivePort'
    Wait-Until { Test-Path -LiteralPath $portFile -PathType Leaf } 'Chrome did not start DevTools'
    $port = [int](Get-Content -LiteralPath $portFile -TotalCount 1)
    $browserInfo = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/json/version" -UseBasicParsing).Content |
        ConvertFrom-Json
    $browser = Open-Cdp -WebSocketUrl $browserInfo.webSocketDebuggerUrl

    $loaded = (Invoke-Cdp -Connection $browser -Method 'Extensions.getExtensions' -Params @{
        includeDisabled = $true
    }).extensions | Where-Object { $_.path -ieq $ExtensionPath -and $_.enabled }
    Assert-Result (@($loaded).Count -eq 1) 'The unpacked extension was not enabled'
    $extensionId = $loaded.id
    $manifest = Get-Content -LiteralPath (Join-Path $ExtensionPath 'manifest.json') -Raw | ConvertFrom-Json
    Assert-Result ($loaded.version -eq $manifest.version) 'Chrome loaded a different extension version'

    $pageId = (Invoke-Cdp -Connection $browser -Method 'Target.createTarget' -Params @{
        url = 'chrome://newtab/'
    }).targetId
    $page = Open-Cdp -WebSocketUrl "ws://127.0.0.1:$port/devtools/page/$pageId"
    [void](Invoke-Cdp -Connection $page -Method 'Runtime.enable')
    [void](Invoke-Cdp -Connection $page -Method 'Log.enable')
    Wait-Until {
        (Invoke-Js $page 'location.href') -eq "chrome-extension://$extensionId/newtab.html"
    } 'Chrome did not apply the new-tab override'

    $fixture = Invoke-Js $page @'
(async () => {
  const roots = (await chrome.bookmarks.getTree())[0].children;
  const bar = roots.find(node => node.folderType === 'bookmarks-bar');
  const other = roots.find(node => node.folderType === 'other');
  if (!bar || !other) throw new Error('Bookmark roots missing');
  const folder = await chrome.bookmarks.create({parentId: bar.id, title: 'Codex Browser Test'});
  const nested = await chrome.bookmarks.create({parentId: folder.id, title: 'Nested Folder'});
  const link = await chrome.bookmarks.create({parentId: nested.id, title: 'Inside Link',
    url: 'https://example.com/inside'});
  const outside = await chrome.bookmarks.create({parentId: other.id, title: 'Outside Link',
    url: 'https://example.com/outside'});
  return {folderId: folder.id, nestedId: nested.id, linkId: link.id, outsideId: outside.id};
})()
'@

    Wait-Until {
        [bool](Invoke-Js $page @'
(() => {
  const folders = [...document.querySelectorAll('#bookmarks .folder')];
  const nested = folders.find(node => node.querySelector(':scope > .title')?.innerText === 'Nested Folder');
  const inside = nested?.querySelector('.item[title="Inside Link"]');
  const outside = document.querySelector('#bookmarks .item[title="Outside Link"]');
  return !!inside && !!outside && inside.querySelector('img')?.naturalWidth > 0;
})()
'@)
    } 'Nested bookmarks or favicon did not render'

    [void](Invoke-Js $page "chrome.bookmarks.update('$($fixture.linkId)', {title: 'Renamed Inside Link'})")
    Wait-Until {
        [bool](Invoke-Js $page '!!document.querySelector("#bookmarks .item[title=\"Renamed Inside Link\"]")')
    } 'Bookmark rename did not reach the new-tab page'
    $transientId = Invoke-Js $page @"
chrome.bookmarks.create({parentId: '$($fixture.nestedId)', title: 'Transient Link',
  url: 'https://example.com/transient'}).then(bookmark => bookmark.id)
"@
    Wait-Until {
        [bool](Invoke-Js $page '!!document.querySelector("#bookmarks .item[title=\"Transient Link\"]")')
    } 'Bookmark creation did not reach the new-tab page'
    [void](Invoke-Js $page "chrome.bookmarks.remove('$transientId')")
    Wait-Until {
        [bool](Invoke-Js $page '!document.querySelector("#bookmarks .item[title=\"Transient Link\"]")')
    } 'Bookmark removal did not reach the new-tab page'

    $optionsId = (Invoke-Cdp -Connection $browser -Method 'Target.createTarget' -Params @{
        url = "chrome-extension://$extensionId/options.html"
    }).targetId
    $options = Open-Cdp -WebSocketUrl "ws://127.0.0.1:$port/devtools/page/$optionsId"
    [void](Invoke-Cdp -Connection $options -Method 'Runtime.enable')
    [void](Invoke-Cdp -Connection $options -Method 'Log.enable')
    Wait-Until {
        [bool](Invoke-Js $options 'document.querySelector("#bookmarks .title") !== null')
    } 'Options page did not initialize'

    $preferences = Invoke-Js $options @'
(async () => {
  [...document.querySelectorAll('#bookmarks .title')]
    .find(node => node.innerText === 'Codex Browser Test').click();
  [...document.querySelectorAll('#font_size div')]
    .find(node => node.innerText.includes('18px')).click();
  return await chrome.storage.local.get(['root_id', 'font_size']);
})()
'@
    Assert-Result ($preferences.root_id -eq $fixture.folderId -and $preferences.font_size -eq 18) `
        'Options did not store the selected root and font size'
    Wait-Until {
        [bool](Invoke-Js $page @'
(() => document.body.style.fontSize === '18px' &&
  !!document.querySelector('#bookmarks .item[title="Renamed Inside Link"]') &&
  !document.querySelector('#bookmarks .item[title="Outside Link"]'))()
'@)
    } 'Stored preferences did not update the new-tab page'

    $closed = Invoke-Js $page @'
(async () => {
  document.querySelector('#bookmarks .folder > .title').click();
  return {className: document.querySelector('#bookmarks > div').className,
    stoplist: (await chrome.storage.local.get('stoplist')).stoplist};
})()
'@
    Assert-Result ($closed.className -eq 'closed-folder' -and $closed.stoplist.$($fixture.nestedId)) `
        'Folder collapse did not persist'
    [void](Invoke-Cdp -Connection $page -Method 'Page.reload' -Params @{ignoreCache = $true})
    Wait-Until {
        [bool](Invoke-Js $page @'
(() => document.readyState === 'complete' && document.body.style.fontSize === '18px' &&
  document.querySelector('#bookmarks > div')?.className === 'closed-folder')()
'@)
    } 'Font size or folder collapse did not survive reload'
    [void](Invoke-Js $page 'document.querySelector("#bookmarks .closed-folder > .title").click()')

    foreach ($case in @(
        @{shift = $true; ctrl = $false; active = $true; name = 'Shift'},
        @{shift = $false; ctrl = $true; active = $false; name = 'Ctrl'},
        @{shift = $true; ctrl = $true; active = $true; name = 'Shift+Ctrl'}
    )) {
        $beforeIds = @(Get-TargetInfos $browser | Where-Object { $_.type -eq 'page' } |
            ForEach-Object { $_.targetId })
        $shiftText = $case.shift.ToString().ToLowerInvariant()
        $ctrlText = $case.ctrl.ToString().ToLowerInvariant()
        $tabs = Invoke-Js $page @"
(async () => {
  const before = await chrome.tabs.query({});
  document.querySelector('#bookmarks .item').dispatchEvent(
    new MouseEvent('click', {bubbles: true, shiftKey: $shiftText, ctrlKey: $ctrlText})
  );
  await new Promise(resolve => setTimeout(resolve, 350));
  const after = await chrome.tabs.query({});
  return {count: after.length - before.length,
    newTabs: after.filter(tab => !before.some(old => old.id === tab.id))
      .map(tab => ({active: tab.active}))};
})()
"@
        Assert-Result ($tabs.count -eq 1 -and @($tabs.newTabs).Count -eq 1 -and
            $tabs.newTabs[0].active -eq $case.active) "$($case.name) click opened the wrong tab state"
        $newTarget = @(Get-TargetInfos $browser | Where-Object {
            $_.type -eq 'page' -and $_.targetId -notin $beforeIds
        })
        Assert-Result ($newTarget.Count -eq 1) "$($case.name) click did not create one page target"
        $createdId = $newTarget[0].targetId
        Wait-Until {
            $target = Get-TargetInfos $browser | Where-Object { $_.targetId -eq $createdId }
            $target.url -eq 'https://example.com/inside'
        } "$($case.name) click opened the wrong destination"
    }

    $actionTab = Invoke-Js $options 'chrome.tabs.create({url:"https://example.com/action",active:true}).then(tab=>tab.id)'
    Wait-Until {
        [bool](Get-TargetInfos $browser | Where-Object {
            $_.type -eq 'tab' -and $_.url -like 'https://example.com/action*'
        })
    } 'Action test tab was not created'
    $actionTarget = Get-TargetInfos $browser | Where-Object {
        $_.type -eq 'tab' -and $_.url -like 'https://example.com/action*'
    } | Select-Object -First 1
    [void](Invoke-Cdp -Connection $options -Method 'ServiceWorker.enable')
    [void](Invoke-Cdp -Connection $options -Method 'ServiceWorker.startWorker' -Params @{
        scopeURL = "chrome-extension://$extensionId/"
    })
    [void](Invoke-Cdp -Connection $options -Method 'Runtime.evaluate' -Params @{
        expression = '1'; returnByValue = $true
    })
    $workerVersion = @($options.Events | Where-Object {
        $_.method -eq 'ServiceWorker.workerVersionUpdated'
    } | ForEach-Object { $_.params.versions } | Where-Object {
        $_.scriptURL -eq "chrome-extension://$extensionId/background.js"
    } | Select-Object -Last 1)
    Assert-Result ($workerVersion.Count -eq 1) 'The extension service worker version was not reported'
    $options.Events.Clear()
    [void](Invoke-Cdp -Connection $options -Method 'ServiceWorker.stopWorker' -Params @{
        versionId = $workerVersion[0].versionId
    })
    Wait-Until {
        [void](Invoke-Cdp -Connection $options -Method 'Runtime.evaluate' -Params @{
            expression = '1'; returnByValue = $true
        })
        [bool]($options.Events | Where-Object {
            $_.method -eq 'ServiceWorker.workerVersionUpdated'
        } | ForEach-Object { $_.params.versions } | Where-Object {
            $_.scriptURL -eq "chrome-extension://$extensionId/background.js" -and
            $_.runningStatus -eq 'stopped'
        })
    } 'The service worker did not stop'
    [void](Invoke-Cdp -Connection $browser -Method 'Extensions.triggerAction' -Params @{
        id = $extensionId; targetId = $actionTarget.targetId
    })
    Wait-Until {
        (Get-TargetInfos $browser | Where-Object {
            $_.targetId -eq $actionTarget.targetId
        }).url -eq 'chrome://newtab/'
    } 'Toolbar action did not navigate after worker restart'

    [void](Invoke-Cdp -Connection $options -Method 'ServiceWorker.startWorker' -Params @{
        scopeURL = "chrome-extension://$extensionId/"
    })
    Wait-Until {
        [bool](Get-TargetInfos $browser | Where-Object {
            $_.type -eq 'service_worker' -and
            $_.url -eq "chrome-extension://$extensionId/background.js"
        })
    } 'The service worker did not restart for error capture'
    $workerTarget = Get-TargetInfos $browser | Where-Object {
        $_.type -eq 'service_worker' -and
        $_.url -eq "chrome-extension://$extensionId/background.js"
    } | Select-Object -First 1
    $worker = Open-Cdp -WebSocketUrl "ws://127.0.0.1:$port/devtools/page/$($workerTarget.targetId)"
    [void](Invoke-Cdp -Connection $worker -Method 'Runtime.enable')
    [void](Invoke-Cdp -Connection $worker -Method 'Log.enable')
    [void](Invoke-Js $options 'chrome.tabs.create({url:"https://example.com/worker-check",active:true})')
    Wait-Until {
        [bool](Get-TargetInfos $browser | Where-Object {
            $_.type -eq 'tab' -and $_.url -like 'https://example.com/worker-check*'
        })
    } 'Worker check tab was not created'
    $checkTarget = Get-TargetInfos $browser | Where-Object {
        $_.type -eq 'tab' -and $_.url -like 'https://example.com/worker-check*'
    } | Select-Object -First 1
    [void](Invoke-Cdp -Connection $browser -Method 'Extensions.triggerAction' -Params @{
        id = $extensionId; targetId = $checkTarget.targetId
    })
    Wait-Until {
        (Get-TargetInfos $browser | Where-Object {
            $_.targetId -eq $checkTarget.targetId
        }).url -eq 'chrome://newtab/'
    } 'Toolbar action failed while worker errors were monitored'
    Assert-Result ([bool](Invoke-Js $worker 'chrome.action.onClicked.hasListeners()')) `
        'Service worker action listener is missing'
    Assert-Result (@(Get-ExtensionErrors $worker).Count -eq 0) 'Service worker emitted an error'

    $reset = Invoke-Js $options @'
(async () => {
  window.confirm = () => true;
  document.getElementById('reset').click();
  await new Promise(resolve => setTimeout(resolve, 150));
  return {storage: await chrome.storage.local.get(null),
    bookmark: (await chrome.bookmarks.get('REPLACE_FOLDER_ID'))[0].title};
})()
'@.Replace('REPLACE_FOLDER_ID', $fixture.folderId)
    Assert-Result (@($reset.storage.PSObject.Properties).Count -eq 0 -and
        $reset.bookmark -eq 'Codex Browser Test') "Reset altered bookmarks or kept preferences: $(ConvertTo-Json -InputObject $reset -Depth 5 -Compress)"

    $currentPageTab = Invoke-Js $page 'chrome.tabs.getCurrent().then(tab=>tab.id)'
    [void](Invoke-Js $page "chrome.tabs.update($currentPageTab,{active:true})")
    $pageCountBefore = @(Get-TargetInfos $browser | Where-Object { $_.type -eq 'page' }).Count
    [void](Invoke-Js $page @'
document.querySelector('#bookmarks .item[title="Renamed Inside Link"]')
  .dispatchEvent(new MouseEvent('click', {bubbles: true}));
true
'@)
    Wait-Until {
        (Get-TargetInfos $browser | Where-Object { $_.targetId -eq $pageId }).url -eq
            'https://example.com/inside'
    } 'Ordinary click did not navigate the active tab'
    $pageCountAfter = @(Get-TargetInfos $browser | Where-Object { $_.type -eq 'page' }).Count
    Assert-Result ($pageCountAfter -eq $pageCountBefore) 'Ordinary click opened an extra tab'

    $folderId = $fixture.folderId
    $outsideId = $fixture.outsideId
    [void](Invoke-Js $options "(async()=>{await chrome.bookmarks.removeTree('$folderId');await chrome.bookmarks.remove('$outsideId');return true})()")
    $fixtureRemaining = Invoke-Js $options @'
chrome.bookmarks.getTree().then(tree => tree[0].children
  .flatMap(root => root.children || [])
  .some(node => node.title === 'Codex Browser Test' || node.title === 'Outside Link'))
'@
    Assert-Result (-not $fixtureRemaining) 'The isolated bookmark fixture was not removed'
    Assert-Result (@(Get-ExtensionErrors $page).Count -eq 0) 'New-tab page emitted an error'
    Assert-Result (@(Get-ExtensionErrors $options).Count -eq 0) 'Options page emitted an error'

    Write-Output "PASS: $($browserInfo.Browser); extension $($loaded.version); browser flows and errors"
} finally {
    foreach ($connection in @($worker, $options, $page, $browser)) {
        if ($null -ne $connection) { Close-Cdp $connection }
    }
    if ($null -ne $chrome) {
        $running = Get-Process -Id $chrome.Id -ErrorAction SilentlyContinue
        if ($running -and $running.Path -ieq $ChromePath) {
            Stop-Process -Id $chrome.Id
        }
    }
    Write-Output "Profile and Chrome stderr: $profilePath"
}
