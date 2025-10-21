#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

module.exports = function (ctx) {
  // Cordova has added file provider path: https://github.com/apache/cordova-android/commit/b773ae48f44a8610366c81bda509d821a6d949ef
  // The path only has cache path.
  // Uses cordova hooks to include another paths.
  
  const filePath = path.join(
    ctx.opts.projectRoot,
    'platforms/android/app/src/main/res/xml/cdv_core_file_provider_paths.xml'
  );

  if (!fs.existsSync(filePath)) {
    console.warn('[Hook] File not found:', filePath);
    return;
  }

  let xml = fs.readFileSync(filePath, 'utf8');

  const hasCachePath = xml.includes('<cache-path');
  const hasExternalPath = xml.includes('<external-path');

  if (!hasCachePath || !hasExternalPath) {
    let injection = '';

    //add cache & external-path in cdv_core_file_provider_paths.xml
    if (!hasCachePath) {
      injection += `\n    <cache-path name="cache" path="." />`;
    }

    if (!hasExternalPath) {
      injection += `\n    <external-path name="external_files" path="." />`;
    }

    xml = xml.replace('</paths>', `${injection}\n</paths>`);

    fs.writeFileSync(filePath, xml, 'utf8');

    console.log('\x1b[32m%s\x1b[0m', '[Hook] Injected cache and external paths into cdv_core_file_provider_paths.xml');
  } else {
    console.log('\x1b[33m%s\x1b[0m', '[Hook] cache-path and external-path already exist, skipping injection.');
  }
};
