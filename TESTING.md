# Testing

## Automated checks

From the repository root, run the focused regression suite with Node.js:

```powershell
node --test tests/mv3.test.js
```

To check the syntax of every extension and test JavaScript file in PowerShell:

```powershell
Get-ChildItem -Path bookmarks-on-new-tab,tests -Filter *.js -File |
  ForEach-Object {
    node --check $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Syntax check failed: $($_.FullName)" }
  }
```

The regression suite reads the real manifest and HTML script lists, executes the extension's
JavaScript against small Chrome API and DOM fixtures, and checks the Manifest V3 declarations,
toolbar action, bookmark initialization, favicon URL, and link modifiers. These tests do not
replace a browser run.

## Browser validation recorded on 2026-10-04

The unpacked extension was loaded in an isolated profile using official Chrome for Testing
Stable 154.0.8037.92 for Windows, with `--headless=new`, `--load-extension`,
`--disable-extensions-except`, and an ephemeral DevTools port. A temporary PowerShell/.NET
DevTools Protocol client drove the browser; that one-off client was not added to the repository.

The browser accepted extension version 0.6.0.0 and resolved `chrome://newtab/` to its new-tab
page. A nested bookmark fixture rendered with the expected titles and hierarchy, and its favicon
image loaded. Creating, renaming, and removing bookmarks updated the page. Selecting a subtree
in options filtered the page; the font size and collapsed-folder state survived a reload.

Ordinary, Shift, Ctrl, and Shift+Ctrl bookmark clicks were exercised against browser tabs.
Ordinary click navigated the active tab, Shift opened a foreground tab, Ctrl opened a background
tab, and Shift+Ctrl followed Shift. After the extension service worker was explicitly stopped,
triggering the toolbar action on an active tab restarted it and navigated that tab to the new-tab
page. The options reset cleared extension storage and left bookmarks intact.

DevTools `Runtime.exceptionThrown` and `Log.entryAdded` captured no errors from the new-tab page,
options page, or service worker during the checked flows. Chrome's own stderr contained network,
GCM, and profile-type messages, so this observation is limited to extension script errors.
The disposable profile's test bookmarks and storage were cleared after the run.

The focused Node tests passed. An independent read-only reviewer reran them and checked an
in-memory baseline against the pre-migration upstream files: the migration checks failed for
the expected reasons, while the existing modifier behavior passed. The reviewer did not repeat
the browser session. The repository's JSHint script was not run because JSHint was unavailable.

## Repeat the browser checks manually

Load `bookmarks-on-new-tab/` as an unpacked extension in a current Chrome release. Create a
folder with a nested folder and bookmark, then open a new tab and check the tree and favicon.
Use the options page to select the nested subtree, change the font size, and collapse a folder;
reload the new tab to check persistence. Create, rename, and delete a bookmark while the new-tab
page is open. Try each link modifier combination, then use the toolbar action from an active
ordinary tab. Finally, reset the extension in options and confirm that bookmarks remain.
