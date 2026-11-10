import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/ai_model.dart';
import '../../ai/battle_engine.dart';
import '../replay/replay_screen.dart';

/// AI 对战模式界面：选择两个模型，自动运行 N 局，统计胜率，支持复盘回放。
class BattleScreen extends ConsumerStatefulWidget {
  const BattleScreen({super.key});

  @override
  ConsumerState<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends ConsumerState<BattleScreen> {
  AIModel _landlordModel = AIModel.douzeroWP;
  AIModel _farmerModel = AIModel.douzeroWP;
  int _totalGames = 30;

  BattleEngine? _engine;
  BattleStats? _stats;
  bool _running = false;
  int _progress = 0;
  int? _selectedReplayIndex;

  @override
  void dispose() {
    _engine?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _running = true;
      _progress = 0;
      _stats = null;
      _selectedReplayIndex = null;
    });

    final config = BattleConfig(
      landlordModel: _landlordModel,
      farmerModel: _farmerModel,
      totalGames: _totalGames,
      seed: math.Random().nextInt(1 << 30),
    );

    _engine = BattleEngine(config: config);
    final stats = await _engine!.run(
      onProgress: (done, total) {
        if (mounted) setState(() => _progress = done);
      },
    );

    if (mounted) {
      setState(() {
        _running = false;
        _stats = stats;
      });
    }
  }

  void _cancel() {
    _engine?.cancel();
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B5E20),
      appBar: AppBar(
        title: const Text('AI 对战测试', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF0D3F12),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_running)
            IconButton(icon: const Icon(Icons.stop), onPressed: _cancel),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildConfigPanel(),
              const SizedBox(height: 16),
              _buildStartButton(),
              if (_running || _progress > 0) ...[
                const SizedBox(height: 12),
                _buildProgressBar(),
              ],
              if (_stats != null) ...[
                const SizedBox(height: 20),
                _buildResults(),
                const SizedBox(height: 16),
                _buildReplayList(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfigPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRoleRow(
            icon: Icons.star,
            label: '地主',
            current: _landlordModel,
            onChanged: (m) => setState(() => _landlordModel = m),
          ),
          const SizedBox(height: 10),
          _buildRoleRow(
            icon: Icons.people,
            label: '农民',
            current: _farmerModel,
            onChanged: (m) => setState(() => _farmerModel = m),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.replay, size: 16, color: Colors.white54),
              const SizedBox(width: 6),
              const Text(
                '局数',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: _totalGames.toDouble(),
                  min: 10,
                  max: 100,
                  divisions: 9,
                  label: '$_totalGames',
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _totalGames = v.round()),
                ),
              ),
              Text(
                '$_totalGames',
                style: const TextStyle(color: Colors.amber, fontSize: 13),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRoleRow({
    required IconData icon,
    required String label,
    required AIModel current,
    required ValueChanged<AIModel> onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white70),
        const SizedBox(width: 6),
        SizedBox(
          width: 36,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: AIModel.all.map((m) {
                final sel = m == current;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(
                      m.shortName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sel ? Colors.black : Colors.black87,
                      ),
                    ),
                    selected: sel,
                    selectedColor: Colors.amber,
                    backgroundColor: sel ? Colors.amber : Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    onSelected: _running ? null : (_) => onChanged(m),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStartButton() {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: _running ? Colors.grey : Colors.orange.shade700,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      onPressed: _running ? null : _start,
      icon: const Icon(Icons.play_arrow),
      label: Text(_running ? '对战中…' : '开始对战'),
    );
  }

  Widget _buildProgressBar() {
    return Column(
      children: [
        LinearProgressIndicator(
          value: _totalGames > 0 ? _progress / _totalGames : 0,
          backgroundColor: Colors.white12,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(height: 4),
        Text(
          _running
              ? '$_progress / $_totalGames'
              : '已完成 $_progress / $_totalGames',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildResults() {
    final s = _stats!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.config.displayName,
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _statItem(
                  '地主胜',
                  '${(s.landlordWinRate * 100).toStringAsFixed(1)}%',
                  '${s.landlordWins}局',
                  s.landlordWinRate >= 0.5
                      ? Colors.greenAccent
                      : Colors.redAccent,
                ),
              ),
              Expanded(
                child: _statItem(
                  '农民胜',
                  '${(s.farmerWinRate * 100).toStringAsFixed(1)}%',
                  '${s.farmerWins}局',
                  s.farmerWinRate >= 0.5
                      ? Colors.greenAccent
                      : Colors.redAccent,
                ),
              ),
              Expanded(
                child: _statItem(
                  '平均倍数',
                  '${s.avgMultiplier.toStringAsFixed(1)}×',
                  '${s.gamesPlayed}局',
                  Colors.amber,
                ),
              ),
              Expanded(
                child: _statItem(
                  '平均回合',
                  '${s.avgMoves.toStringAsFixed(0)}手',
                  '每局',
                  Colors.white70,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statItem(String label, String value, String sub, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 9)),
      ],
    );
  }

  Widget _buildReplayList() {
    final s = _stats!;
    final showCount = s.details.length > 10 ? 10 : s.details.length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 14, color: Colors.white54),
              const SizedBox(width: 4),
              Text(
                '对局复盘（最近 $showCount 局）',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < showCount; i++) _replayChip(i, s.details[i]),
            ],
          ),
          if (s.details.length > 10)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '（共 ${s.details.length} 局，仅展示最近 10 局）',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  Widget _replayChip(int index, BattleGameResult result) {
    final isWin = result.landlordWin;
    return GestureDetector(
      onTap: () => _openReplay(index, result),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _selectedReplayIndex == index
              ? Colors.amber.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isWin
                ? Colors.green.withValues(alpha: 0.4)
                : Colors.red.withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          '#${index + 1} ${isWin ? '主胜' : '农胜'} ×${result.multiplier}',
          style: TextStyle(
            color: isWin ? Colors.greenAccent : Colors.redAccent,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  void _openReplay(int index, BattleGameResult result) {
    setState(() => _selectedReplayIndex = index);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReplayScreen(
          replayLog: result.replayLog,
          finalState: result.finalState,
        ),
      ),
    );
  }
}
