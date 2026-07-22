/**
 * @license
 * Copyright 2026 Vybestack LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import { describe, expect, it } from 'vitest';
import yaml from 'js-yaml';
import * as fs from 'fs';
import * as path from 'path';
import { normalize, readRootFile } from './ocr-review-workflow-helpers.js';

const ROOT = path.resolve(import.meta.dirname, '../..');

function loadWorkflow(relPath) {
  const source = readRootFile(relPath);
  const parsed = yaml.load(source);
  if (!parsed || typeof parsed !== 'object') {
    throw new Error(`${relPath} did not parse to a YAML object`);
  }
  return { source, workflow: parsed };
}

describe('.github/workflows/assign.yml', () => {
  const { source, workflow } = loadWorkflow('.github/workflows/assign.yml');
  const job = workflow.jobs?.assign;

  it('triggers on issue_comment created only', () => {
    expect(workflow.on?.issue_comment?.types).toEqual(['created']);
    expect(workflow.on?.pull_request).toBeUndefined();
  });

  it('uses least-privilege permissions', () => {
    expect(workflow.permissions).toEqual({
      contents: 'read',
      issues: 'write',
    });
  });

  it('gates on exact /assign for issues (not PRs)', () => {
    expect(job, 'assign job should exist').toBeTruthy();
    const condition = normalize(job.if);
    expect(condition).toContain('github.event.issue.pull_request == null');
    expect(condition).toContain("github.event.comment.body == '/assign'");
    expect(condition).toContain(
      `toJSON(github.event.comment.body) == '"/assign\\n"'`,
    );
    expect(condition).toContain(
      `toJSON(github.event.comment.body) == '"/assign\\r\\n"'`,
    );
    // Must not use startsWith, which would accept `/assign foo`.
    expect(source).not.toMatch(
      /startsWith\(toJSON\(github\.event\.comment\.body\)/,
    );
  });

  it('scopes concurrency by workflow and issue number', () => {
    expect(job.concurrency?.['cancel-in-progress']).toBe(true);
    expect(normalize(job.concurrency?.group)).toBe(
      '${{ github.workflow }}-${{ github.event.issue.number }}',
    );
  });

  it('checks out with the ratchet-pinned checkout action and runs assign-issue.sh', () => {
    const checkout = job.steps?.find((s) => s.name === 'Checkout repository');
    expect(checkout?.uses).toBe(
      'actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8',
    );
    expect(source).toContain(
      'actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # ratchet:actions/checkout@v5',
    );

    const runStep = job.steps?.find(
      (s) => s.name === 'Run assign-issue script',
    );
    expect(runStep?.run).toContain('./.github/scripts/assign-issue.sh');
    expect(runStep?.env?.ISSUE_NUMBER).toBe('${{ github.event.issue.number }}');
    expect(runStep?.env?.COMMENTER_LOGIN).toBe(
      '${{ github.event.comment.user.login }}',
    );
    expect(runStep?.env?.GH_TOKEN).toBe('${{ github.token }}');
  });
});

describe('.github/workflows/assign-stale-cleanup.yml', () => {
  const { workflow } = loadWorkflow(
    '.github/workflows/assign-stale-cleanup.yml',
  );
  const job = workflow.jobs?.cleanup;

  it('runs on a daily schedule and workflow_dispatch', () => {
    expect(workflow.on?.schedule?.[0]?.cron).toBe('0 7 * * *');
    expect(workflow.on?.workflow_dispatch).toBeDefined();
  });

  it('guards scheduled runs to the canonical upstream repository', () => {
    expect(normalize(job?.if)).toContain(
      "github.repository == 'vybestack/llxprt-code'",
    );
    // Do not copy the historical typo from llxprt-scheduled-pr-triage.yml.
    expect(normalize(job?.if)).not.toContain('llpxrt-code');
  });

  it('uses least-privilege permissions and runs the cleanup script', () => {
    expect(workflow.permissions).toEqual({
      contents: 'read',
      issues: 'write',
    });
    const runStep = job.steps?.find(
      (s) => s.name === 'Run unassign-stale-issues script',
    );
    expect(runStep?.run).toContain(
      './.github/scripts/unassign-stale-issues.sh',
    );
  });
});

describe('.github/scripts assign automation', () => {
  it('assign-issue.sh enforces eligibility, cap, label, and sticky feedback', () => {
    const script = fs.readFileSync(
      path.join(ROOT, '.github/scripts/assign-issue.sh'),
      'utf8',
    );
    expect(script).toContain("MARKER='<!-- llxprt-assign-feedback -->'");
    expect(script).toContain("AUTO_ASSIGNED_LABEL='auto-assigned'");
    expect(script).toContain('MAX_ASSIGNMENTS=3');
    expect(script).toContain('trusted-contributors.txt');
    expect(script).toContain('gh search prs');
    expect(script).toContain('--merged');
    expect(script).toContain('--add-assignee');
    expect(script).toContain('post_sticky_feedback');
  });

  it('unassign-stale-issues.sh uses a 14-day window and exempts acoliver', () => {
    const script = fs.readFileSync(
      path.join(ROOT, '.github/scripts/unassign-stale-issues.sh'),
      'utf8',
    );
    expect(script).toContain('STALE_DAYS=14');
    expect(script).toContain("EXEMPT_LOGIN='acoliver'");
    expect(script).toContain("AUTO_ASSIGNED_LABEL='auto-assigned'");
    expect(script).toContain('retry_gh');
    expect(script).toContain('--remove-assignee');
  });
});

describe('CONTRIBUTING.md self-assign docs', () => {
  it('documents /assign eligibility, cap, and stale cleanup', () => {
    const docs = readRootFile('CONTRIBUTING.md');
    expect(docs).toContain('/assign');
    expect(docs).toContain('merged PR');
    expect(docs).toContain('trusted-contributors.txt');
    expect(docs).toContain('3');
    expect(docs).toContain('auto-assigned');
    expect(docs).toContain('2 weeks');
  });
});
