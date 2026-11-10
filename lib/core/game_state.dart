import 'card.dart';
import 'game_phase.dart';
import 'hand_pattern.dart';
import 'rule_variant.dart';

/// 单个玩家在某时刻的可见状态。
class PlayerState {
  final int seat; // 0/1/2
  final PlayerRole role;
  final List<Card> hand; // 该玩家手牌（按 rank 降序）
  final bool isHuman;
  final int playCount; // 本局出牌轮数（春天/反春天判定用）
  final String name; // 玩家显示名（联网模式用）

  const PlayerState({
    required this.seat,
    required this.role,
    required this.hand,
    required this.isHuman,
    this.playCount = 0,
    this.name = '',
  });

  PlayerState copyWith({
    int? seat,
    PlayerRole? role,
    List<Card>? hand,
    bool? isHuman,
    int? playCount,
    String? name,
  }) => PlayerState(
    seat: seat ?? this.seat,
    role: role ?? this.role,
    hand: hand ?? this.hand,
    isHuman: isHuman ?? this.isHuman,
    playCount: playCount ?? this.playCount,
    name: name ?? this.name,
  );

  int get handCount => hand.length;
}

/// 一回合中的「最后一手有效出牌」。
class PlayFrame {
  final int seat;
  final HandPattern pattern;
  final List<Card> cards;
  const PlayFrame(this.seat, this.pattern, this.cards);
}

/// 复盘一步：记录一次动作 + 应用前的快照，方便回放面板逐帧重演。
///
/// - [phase]：应用动作前 [GameState] 的阶段（用于在 UI 上区分叫地主/出牌）。
/// - [seat]：动作发起者座位；叫地主发牌/系统动作为 -1。
/// - [kind]：动作类型（用于回放 UI 标识）。
/// - [cards]：本步涉及的牌（出牌=出的牌；叫地主成交=底牌；pass/纯叫分=空）。
/// - [snapshotBefore]：本步应用前的完整状态（含三方手牌），让回放无需重放历史。
class ReplayStep {
  final GamePhase phase;
  final int seat;
  final ReplayStepKind kind;
  final List<Card> cards;
  final GameState snapshotBefore;

  const ReplayStep({
    required this.phase,
    required this.seat,
    required this.kind,
    required this.cards,
    required this.snapshotBefore,
  });
}

/// 复盘步类型。
enum ReplayStepKind {
  deal, // 发牌
  bid, // 叫分（含不叫）
  bidSettle, // 叫地主成交（地主拿底牌）
  play, // 出牌
  pass, // 不出
}

/// 游戏全局状态的不可变快照。
///
/// 所有字段在状态转移后通过 [copyWith] 产生新实例（函数式更新）。
/// 参见 docs/05-architecture.md §2.1。
class GameState {
  final GamePhase phase;
  final List<PlayerState> players; // 长度 3，按 seat 索引
  final int currentPlayer; // 当前轮到谁
  final int? landlordSeat;
  final List<Card> bottomCards;
  final PlayFrame? lastValidPlay;
  final int passCount; // 当前回合连续 pass 数
  final int multiplier; // 倍数（初始 = 叫分，炸弹/火箭 ×2）
  final bool isSpring; // 春天（地主胜 + 两农民都未出过牌）
  final bool isAntiSpring; // 反春天（农民胜 + 地主未出过牌）
  final int deckSeed;
  final int? winnerSeat; // 结算时获胜者座位（null 表示未结束）
  final List<Card>
  playedCards; // 已真正打出去的牌（PlayAction 累加；不含底牌——底牌进入地主手牌后由 PlayAction 自然加入）

  // 按座位细分（DouZero 特征编码必需；其他模块透明）：
  // playedBySeat[s] = 座位 s 自开局以来累计出过的牌（不含 pass），含成交时公开的底牌
  // lastMoveBySeat[s] = 座位 s 最近一手有效出牌（pass 后置为空列表）
  // actionSeq = 出牌顺序（含 pass 记为 []），按时间正序；DouZero LSTM 取最后 15 步
  final Map<int, List<Card>> playedBySeat;
  final Map<int, List<Card>> lastMoveBySeat;
  final List<List<Card>> actionSeq;

  /// 本轮已行动过的座位（play 或 pass），用于 UI 判断是否展示对手上一手动作。
  /// 每轮出牌开始（两轮 pass 后或新局发牌后）清空。
  final Set<int> actedSeats;

  /// 联网模式下，已提交但未确认的牌索引（乐观更新 pending 状态）。
  /// UI 将这些牌灰显；单机模式恒为空。
  final Set<int> pendingCardIndices;

  /// 联网模式下，当前回合截止时间（UTC 毫秒）。null 表示无限时（单机/AI 回合）。
  final int? turnDeadline;

  /// 联网模式下，处于托管状态的显示座位集合（超时后 AI 接管）。
  final Set<int> autoPlaySeats;

  /// 联网模式下，各实际座位的在线状态（索引=实际座位）。
  /// 单机模式恒为 [true, true, true]。
  final List<bool> seatOnline;

  /// 复盘日志：每一步动作的快照，供结算后 ReplayScreen 逐帧重演。
  /// 注意：每个快照包含完整三方手牌—— ReplayScreen 直接读 snapshotBefore 即可。
  final List<ReplayStep> replayLog;

  // 叫地主阶段专用
  final int currentMaxBid; // 当前最高叫分（0 表示无人叫）
  final int? highestBidder; // 当前最高叫者座位
  final int bidParticipants; // 已参与叫分的人数（含不叫）

  /// 规则变体（随状态序列化，引擎/UI/回放统一读取）。
  final RuleVariant ruleVariant;

  /// 明牌座位集合（叫地主阶段主动明牌，倍数×2/人）。
  final Set<int> brightSeats;

  GameState({
    required this.phase,
    required this.players,
    required this.currentPlayer,
    this.landlordSeat,
    required this.bottomCards,
    this.lastValidPlay,
    this.passCount = 0,
    this.multiplier = 1,
    this.isSpring = false,
    this.isAntiSpring = false,
    required this.deckSeed,
    this.winnerSeat,
    this.playedCards = const [],
    Map<int, List<Card>>? playedBySeat,
    Map<int, List<Card>>? lastMoveBySeat,
    List<List<Card>>? actionSeq,
    List<ReplayStep>? replayLog,
    this.currentMaxBid = 0,
    this.highestBidder,
    this.bidParticipants = 0,
    Set<int>? actedSeats,
    Set<int>? pendingCardIndices,
    this.turnDeadline,
    Set<int>? autoPlaySeats,
    List<bool>? seatOnline,
    this.ruleVariant = RuleVariant.classic,
    this.brightSeats = const {},
  }) : playedBySeat = playedBySeat ?? const {0: [], 1: [], 2: []},
       lastMoveBySeat = lastMoveBySeat ?? const {0: [], 1: [], 2: []},
       actionSeq = actionSeq ?? const [],
       actedSeats = actedSeats ?? const {},
       pendingCardIndices = pendingCardIndices ?? const {},
       autoPlaySeats = autoPlaySeats ?? const {},
       seatOnline = seatOnline ?? const [true, true, true],
       replayLog = replayLog ?? const [];

  /// 初始空状态（未发牌）。
  factory GameState.initial() => GameState(
    phase: GamePhase.dealing,
    players: const [],
    currentPlayer: 0,
    bottomCards: const [],
    deckSeed: 0,
  );

  GameState copyWith({
    GamePhase? phase,
    List<PlayerState>? players,
    int? currentPlayer,
    Object? landlordSeat = _sentinel,
    Object? lastValidPlay = _sentinel,
    int? passCount,
    int? multiplier,
    bool? isSpring,
    bool? isAntiSpring,
    List<Card>? bottomCards,
    int? deckSeed,
    Object? winnerSeat = _sentinel,
    List<Card>? playedCards,
    Map<int, List<Card>>? playedBySeat,
    Map<int, List<Card>>? lastMoveBySeat,
    List<List<Card>>? actionSeq,
    List<ReplayStep>? replayLog,
    int? currentMaxBid,
    Object? highestBidder = _sentinel,
    int? bidParticipants,
    Set<int>? actedSeats,
    Set<int>? pendingCardIndices,
    int? turnDeadline,
    Set<int>? autoPlaySeats,
    List<bool>? seatOnline,
    RuleVariant? ruleVariant,
    Set<int>? brightSeats,
  }) => GameState(
    phase: phase ?? this.phase,
    players: players ?? this.players,
    currentPlayer: currentPlayer ?? this.currentPlayer,
    landlordSeat: identical(landlordSeat, _sentinel)
        ? this.landlordSeat
        : landlordSeat as int?,
    lastValidPlay: identical(lastValidPlay, _sentinel)
        ? this.lastValidPlay
        : lastValidPlay as PlayFrame?,
    passCount: passCount ?? this.passCount,
    multiplier: multiplier ?? this.multiplier,
    isSpring: isSpring ?? this.isSpring,
    isAntiSpring: isAntiSpring ?? this.isAntiSpring,
    bottomCards: bottomCards ?? this.bottomCards,
    deckSeed: deckSeed ?? this.deckSeed,
    winnerSeat: identical(winnerSeat, _sentinel)
        ? this.winnerSeat
        : winnerSeat as int?,
    playedCards: playedCards ?? this.playedCards,
    playedBySeat: playedBySeat ?? this.playedBySeat,
    lastMoveBySeat: lastMoveBySeat ?? this.lastMoveBySeat,
    actionSeq: actionSeq ?? this.actionSeq,
    replayLog: replayLog ?? this.replayLog,
    currentMaxBid: currentMaxBid ?? this.currentMaxBid,
    highestBidder: identical(highestBidder, _sentinel)
        ? this.highestBidder
        : highestBidder as int?,
    bidParticipants: bidParticipants ?? this.bidParticipants,
    actedSeats: actedSeats ?? this.actedSeats,
    pendingCardIndices: pendingCardIndices ?? this.pendingCardIndices,
    turnDeadline: turnDeadline ?? this.turnDeadline,
    autoPlaySeats: autoPlaySeats ?? this.autoPlaySeats,
    seatOnline: seatOnline ?? this.seatOnline,
    ruleVariant: ruleVariant ?? this.ruleVariant,
    brightSeats: brightSeats ?? this.brightSeats,
  );

  static const _sentinel = Object();
}
