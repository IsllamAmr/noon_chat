#!/usr/bin/env node
const { runCleanup } = require('./lib/cleanup-core');

runCleanup({ argv: process.argv.slice(2), forceConfirmMode: true })
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('\n[DELETE FAILED]', error.message || error);
    console.error(
      'Tip: run dry-run first: node admin-tools/dry-run-delete.js',
    );
    process.exit(1);
  });
