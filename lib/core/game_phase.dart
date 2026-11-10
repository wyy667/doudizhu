/// 对局阶段。参见 docs/05-architecture.md §3 状态机。
enum GamePhase {
  dealing, // 发牌（瞬时）
  bidding, // 叫地主
  playing, // 出牌
  settled, // 已结算
}

/// 玩家身份。
enum PlayerRole {
  undecided, // 未定（叫地主前）
  landlord, // 地主
  farmer, // 农民
}
