#!/usr/bin/env node

/**
 * 斗地主联机后端一键配置脚本
 *
 * 用法：
 *   node supabase/scripts/setup.mjs
 *
 * 前置条件：
 *   1. 已注册 Supabase 账号 (supabase.com) 并创建项目
 *   2. 已注册 LiveKit Cloud (cloud.livekit.io) 并拿到 API Key / Secret / WS URL
 *   3. Node.js >= 18
 */

import { execSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(__dirname, '..', '..');
const rl = createInterface({ input: process.stdin, output: process.stdout });
const prompt = (q) => new Promise((r) => rl.question(q, r));

const C = {
  reset: '\x1b[0m', bold: '\x1b[1m',
  green: '\x1b[32m', yellow: '\x1b[33m', red: '\x1b[31m', cyan: '\x1b[36m',
};

function ok(m)   { console.log(`${C.green}  ✓${C.reset} ${m}`); }
function warn(m) { console.log(`${C.yellow}  ⚠${C.reset} ${m}`); }
function err(m)  { console.log(`${C.red}  ✗${C.reset} ${m}`); }
function info(m) { console.log(`${C.cyan}  →${C.reset} ${m}`); }
function step(n, m) { console.log(`\n${C.bold}${C.cyan}[${n}] ${m}${C.reset}`); }

function run(cmd, opts = {}) {
  return execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], ...opts }).trim();
}

function runInherit(cmd, opts = {}) {
  execSync(cmd, { stdio: 'inherit', ...opts });
}

function runSql(sql) {
  try {
    execSync('supabase db query --linked', {
      input: sql,
      cwd: projectRoot,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, SUPABASE_DB_PASSWORD: dbPassword },
    });
  } catch (e) {
    const stderr = (e.stderr || '').trim();
    throw new Error(stderr || e.message);
  }
}

// ── 全局状态 ──
let dbPassword = '';

async function main() {
  console.log(`\n${C.bold}${C.cyan}╔══════════════════════════════════════════╗
║   斗地主联机后端 · 一键配置脚本         ║
╚══════════════════════════════════════════╝${C.reset}\n`);

  console.log(`${C.bold}前置条件：${C.reset}`);
  console.log('  1. 已注册 Supabase 账号 + 已创建项目 (supabase.com)');
  console.log('  2. 手上有 Supabase 数据库密码（创建项目时设置的）');
  console.log('  3. 已注册 LiveKit Cloud + 已创建项目 (cloud.livekit.io)');
  console.log('  4. 手上有 LiveKit 的 API Key / API Secret / WebSocket URL');
  console.log('  5. Node.js >= 18\n');
  console.log(`${C.yellow}  ⚠ 注意：启用匿名登录需要手动操作（脚本无法自动完成）：${C.reset}`);
  console.log(`${C.yellow}     Dashboard → Authentication → Sign In / Providers →${C.reset}`);
  console.log(`${C.yellow}     Allow anonymous sign-ins → 开启 → Save changes${C.reset}`);
  console.log(`${C.yellow}     建议在运行脚本前先完成此步骤。\n${C.reset}`);

  const ready = await prompt('以上条件已满足？(y/n) ');
  if (ready.toLowerCase() !== 'y') {
    console.log('\n请先完成前置条件后重新运行。');
    rl.close();
    return;
  }

  let failed = 0;

  // ── 1. CLI ──
  step(1, '检查 Supabase CLI');
  try {
    ok(`已安装 ${run('supabase --version')}`);
  } catch {
    info('安装中 (npm install -g supabase) ...');
    runInherit('npm install -g supabase');
    ok('安装完成');
  }

  // ── 2. 登录 ──
  step(2, '登录 Supabase');
  try {
    run('supabase projects list');
    ok('已登录');
  } catch {
    info('将打开浏览器授权...');
    runInherit('supabase login');
    try {
      run('supabase projects list');
      ok('登录成功');
    } catch {
      err('登录验证失败');
      rl.close();
      return;
    }
  }

  // ── 3. 项目 ──
  step(3, '选择项目');
  console.log('  Project URL 格式: https://<project-ref>.supabase.co');
  const ref = (await prompt('  请输入 project-ref: ')).trim();
  if (!ref || ref.length < 8) {
    err('project-ref 无效');
    rl.close();
    return;
  }
  info(`项目: ${ref}`);

  // ── 4. 关联 ──
  step(4, '关联项目');
  try {
    run(`supabase link --project-ref ${ref}`, { cwd: projectRoot });
    ok('关联成功');
  } catch (e) {
    warn(`关联失败: ${e.message}`);
  }

  // ── 5. 数据库密码 ──
  step(5, '获取数据库密码');
  console.log('  创建 Supabase 项目时设置的 Database Password');
  console.log('  （如忘记：Dashboard → Project Settings → Database → Reset database password）');
  dbPassword = (await prompt('  请输入数据库密码: ')).trim();
  if (!dbPassword) {
    err('密码不能为空');
    rl.close();
    return;
  }

  // ── 6. 建表 SQL ──
  step(6, '执行建表 SQL (schema.sql)');
  try {
    const sql = readFileSync(join(projectRoot, 'supabase', 'schema.sql'), 'utf8');
    runSql(sql);
    ok('建表完成');
  } catch (e) {
    err(`失败: ${e.message.split('\n')[0]}`);
    warn('请手动在 Dashboard → SQL Editor 执行 supabase/schema.sql');
    failed++;
  }

  // ── 7. 清理 SQL ──
  step(7, '执行清理 SQL (pg_cron + cleanup)');
  try {
    runSql('CREATE EXTENSION IF NOT EXISTS pg_cron;');
    ok('pg_cron 已启用');
  } catch (e) {
    warn(`pg_cron 启用失败: ${e.message.split('\n')[0]}`);
  }

  try {
    const cleanup = readFileSync(join(projectRoot, 'supabase', 'cleanup_stale_rooms.sql'), 'utf8');
    runSql(cleanup);
    ok('清理函数 + cron 已创建');
  } catch (e) {
    err(`清理 SQL 失败: ${e.message.split('\n')[0]}`);
    warn('请手动在 Dashboard → SQL Editor 执行 supabase/cleanup_stale_rooms.sql');
    failed++;
  }

  // ── 7b. 匿名登录（只能手动）──
  step('7b', '启用匿名登录（需手动操作）');
  console.log(`${C.yellow}  匿名登录只能通过 Dashboard 开启，无法自动完成。${C.reset}`);
  console.log('  路径: Dashboard → Authentication → Sign In / Providers →');
  console.log('        Allow anonymous sign-ins → 开启 → Save changes\n');
  const done = await prompt('  已完成？(y/n) ');
  if (done.toLowerCase() === 'y') {
    ok('匿名登录已启用');
  } else {
    warn('请稍后手动完成此步骤');
  }

  // ── 8. 部署 Edge Function ──
  step(8, '部署 Edge Function (get-voice-token)');
  try {
    run('supabase functions deploy get-voice-token', { cwd: projectRoot });
    ok('部署成功');
  } catch (e) {
    err(`部署失败: ${e.message.split('\n')[0]}`);
    warn('请手动: Dashboard → Edge Functions → Create Function → 粘贴代码 → Deploy');
    failed++;
  }

  // ── 9. LiveKit Secrets ──
  step(9, '设置 LiveKit Secrets');
  console.log('\n  请输入 LiveKit 凭据：');
  const lkKey = (await prompt('  API Key: ')).trim();
  const lkSecret = (await prompt('  API Secret: ')).trim();
  const lkWsUrl = (await prompt('  WebSocket URL (wss://...): ')).trim();
  const adminPw = (await prompt('  管理员密码 (自定义): ')).trim();

  if (lkKey && lkSecret && lkWsUrl && adminPw) {
    try {
      const esc = (s) => s.replace(/"/g, '\\"');
      run(
        `supabase secrets set ` +
        `LIVEKIT_API_KEY="${esc(lkKey)}" ` +
        `LIVEKIT_API_SECRET="${esc(lkSecret)}" ` +
        `LIVEKIT_WS_URL="${esc(lkWsUrl)}" ` +
        `ADMIN_PASSWORD="${esc(adminPw)}"`,
        { cwd: projectRoot },
      );
      ok('Secrets 设置成功');
    } catch (e) {
      err(`Secrets 设置失败: ${e.message.split('\n')[0]}`);
      warn('请手动在 Dashboard → Project Settings → Edge Functions → Secrets 设置');
      failed++;
    }
  } else {
    warn('输入不完整，跳过');
  }

  // ── 10. 获取 API Key + 验证 ──
  step(10, '获取 API Key + 验证配置');

  let publishableKey = null;
  try {
    const out = run(`supabase projects api-keys --project-ref ${ref}`, { cwd: projectRoot });
    // 解析 publishable key（格式 sb_publishable_xxx）
    const m = out.match(/sb_publishable_\S+/);
    if (m) publishableKey = m[0];
  } catch (e) {
    warn('无法自动获取 API Key');
  }

  if (publishableKey) {
    info('测试 Edge Function ...');
    try {
      const res = await fetch(
        `https://${ref}.supabase.co/functions/v1/get-voice-token`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${publishableKey}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ roomId: 'SETUP_TEST', uid: 'setup-test' }),
        },
      );
      const data = await res.json();
      if (data.token) ok('Edge Function + LiveKit 连通正常 ✓');
      else if (data.error) warn(`返回错误: ${data.error}（请检查 LiveKit Secrets）`);
      else warn(`返回异常 (HTTP ${res.status})`);
    } catch (e) {
      warn(`测试失败: ${e.message}`);
      warn('Function 可能需要几秒就绪，可稍后重试');
    }
  }

  // ── 结果输出 ──
  console.log(`\n${C.bold}${C.green}══════════════════════════════════════════${C.reset}`);
  console.log(`${C.bold}${C.green}  配置完成！${C.reset}`);
  if (failed > 0) {
    console.log(`${C.bold}${C.yellow}  （${failed} 步失败，请按提示手动完成）${C.reset}`);
  }
  console.log(`${C.bold}${C.green}══════════════════════════════════════════${C.reset}\n`);

  console.log('将以下信息填入 App → 设置 → 后端配置：\n');
  console.log(`  ${C.bold}Supabase URL${C.reset}:    https://${ref}.supabase.co`);
  if (publishableKey) {
    console.log(`  ${C.bold}Publishable Key${C.reset}: ${publishableKey}`);
  } else {
    console.log(`  ${C.bold}Publishable Key${C.reset}: Dashboard → Project Settings → API → publishable key`);
  }
  console.log('');

  rl.close();
}

main().catch((e) => {
  err(e.message);
  rl.close();
  process.exit(1);
});
