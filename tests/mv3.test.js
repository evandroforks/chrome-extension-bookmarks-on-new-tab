'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const extensionPath = path.join(__dirname, '..', 'bookmarks-on-new-tab');
const extensionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const bookmarkUrl = 'https://example.test/résumé?q=one&two=2#section';

function readExtensionFile(name) {
  return fs.readFileSync(path.join(extensionPath, name), 'utf8');
}

class Element {
  constructor(tagName) {
    this.tagName = tagName;
    this.children = [];
    this.style = {};
    this.className = '';
    this.onclick = null;
    this._innerText = '';
  }

  set innerText(value) {
    this._innerText = value;
    this.children = [];
  }

  get innerText() {
    return this._innerText;
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  removeChild(child) {
    const index = this.children.indexOf(child);
    assert.notEqual(index, -1);
    this.children.splice(index, 1);
    return child;
  }

  querySelectorAll(tagName) {
    return descendants(this).filter((node) => node.tagName === tagName);
  }
}

function descendants(element) {
  return element.children.flatMap((child) => [child, ...descendants(child)]);
}

function pageFixture() {
  const elements = Object.fromEntries(
    ['bookmarks', 'options', 'edit-bookmarks', 'font_size', 'reset'].map((id) => [id, new Element('div')])
  );
  const body = new Element('body');
  const document = {
    createElement: (tagName) => new Element(tagName),
    getElementById: (id) => elements[id],
    getElementsByTagName: (tagName) => tagName === 'body' ? [body] : []
  };
  const calls = {tree: 0, permission: 0, tabCreates: [], tabUpdates: []};
  const tree = [{
    id: '0', title: '', children: [{
      id: '1', title: 'Bookmarks bar', children: [{id: '2', title: 'Résumé', url: bookmarkUrl}]
    }]
  }];
  const event = {addListener() {}};
  const chrome = {
    bookmarks: {
      getTree(callback) { calls.tree++; callback(tree); },
      getSubTree(id, callback) { callback(tree.filter((node) => node.id === id)); },
      onCreated: event, onRemoved: event, onChanged: event, onMoved: event,
      onChildrenReordered: event, onImportEnded: event
    },
    permissions: {
      contains(permissions, callback) { calls.permission++; callback(true); },
      request() { calls.permission++; throw new Error('Unexpected permission request'); }
    },
    runtime: {
      getURL(relativePath) {
        return `chrome-extension://${extensionId}/${relativePath.replace(/^\//, '')}`;
      }
    },
    storage: {
      local: {
        get(defaults, callback) { callback(defaults); },
        set() {}
      },
      onChanged: event
    },
    tabs: {
      create(properties) { calls.tabCreates.push(properties); },
      update(tabId, properties) { calls.tabUpdates.push([tabId, properties]); }
    }
  };
  return {elements, body, document, chrome, calls};
}

function runPage(name) {
  const fixture = pageFixture();
  const context = vm.createContext({
    chrome: fixture.chrome,
    window: {document: fixture.document},
    URL
  });
  const html = readExtensionFile(`${name}.html`);
  const scripts = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((match) => match[1]);
  assert.ok(scripts.includes(`${name}.js`));
  for (const script of scripts) {
    vm.runInContext(readExtensionFile(script), context, {filename: script});
  }
  return fixture;
}

test('manifest declares the MV3 worker, action, pages, and required permissions', () => {
  const manifest = JSON.parse(readExtensionFile('manifest.json'));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.minimum_chrome_version, '104');
  assert.deepEqual([...manifest.permissions].sort(), ['bookmarks', 'favicon', 'storage']);
  assert.deepEqual(manifest.background, {service_worker: 'background.js'});
  assert.equal(manifest.action.default_title, 'Load bookmarks here');
  assert.equal(manifest.chrome_url_overrides.newtab, 'newtab.html');
  assert.equal(manifest.options_page, 'options.html');
  assert.equal(manifest.browser_action, undefined);
  assert.equal(manifest.optional_permissions, undefined);
});

test('worker registers the action synchronously and updates the clicked tab', () => {
  let listener;
  const updates = [];
  const chrome = {
    action: {onClicked: {addListener(callback) { listener = callback; }}},
    tabs: {update(tabId, properties) { updates.push([tabId, properties]); }}
  };
  vm.runInNewContext(readExtensionFile('background.js'), {chrome}, {filename: 'background.js'});
  assert.equal(typeof listener, 'function');
  listener({id: 42});
  assert.equal(updates.length, 1);
  assert.equal(updates[0][0], 42);
  assert.equal(updates[0][1].url, 'chrome://newtab/');
});

test('new tab initializes the bookmark tree without a runtime permission prompt', () => {
  assert.doesNotMatch(readExtensionFile('newtab.html'), /src="permissions\.js"/);
  const {elements, calls} = runPage('newtab');
  assert.equal(calls.permission, 0);
  assert.equal(calls.tree, 1);
  assert.equal(descendants(elements.bookmarks).find((node) => node.className === 'jail-text').innerText, 'Résumé');
  assert.equal(elements['edit-bookmarks'].style.display, 'inline-block');
});

test('options initializes the bookmark selector without a runtime permission prompt', () => {
  assert.doesNotMatch(readExtensionFile('options.html'), /src="permissions\.js"/);
  const {elements, calls} = runPage('options');
  assert.equal(calls.permission, 0);
  assert.equal(calls.tree, 1);
  assert.equal(elements.font_size.children.length, 7);
  assert.equal(descendants(elements.bookmarks).find((node) => node.innerText === 'All').innerText, 'All');
});

test('favicon URL preserves a complete bookmark URL under the extension origin', () => {
  const {elements} = runPage('newtab');
  const image = descendants(elements.bookmarks).find((node) => node.tagName === 'img');
  assert.ok(image);
  const favicon = new URL(image.src);
  assert.equal(favicon.protocol, 'chrome-extension:');
  assert.equal(favicon.host, extensionId);
  assert.equal(favicon.pathname, '/_favicon/');
  assert.equal(favicon.searchParams.get('pageUrl'), bookmarkUrl);
  assert.equal(favicon.searchParams.get('size'), '16');
});

test('upstream link modifiers keep Shift precedence over Ctrl', () => {
  const {elements, calls} = runPage('newtab');
  const item = descendants(elements.bookmarks).find((node) => node.className === 'item');
  for (const [shiftKey, ctrlKey] of [[false, false], [true, false], [false, true], [true, true]]) {
    item.onclick({shiftKey, ctrlKey});
  }
  assert.equal(calls.tabUpdates.length, 1);
  assert.equal(calls.tabUpdates[0][1].url, bookmarkUrl);
  assert.equal(calls.tabCreates.length, 3);
  assert.equal(calls.tabCreates[0].active, undefined);
  assert.equal(calls.tabCreates[1].active, false);
  assert.equal(calls.tabCreates[2].active, undefined);
  assert.ok(calls.tabCreates.every((properties) => properties.url === bookmarkUrl));
});
