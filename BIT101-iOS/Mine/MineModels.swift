//
//  MineModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// “我的”页个人信息接口模型。
///
/// 这个模型既用于“我的主页”，也用于跳到他人主页后的资料卡。
/// 因此除了基础用户信息，还带了关注关系和是否本人这些关系态字段。
struct MineUserInfo: Decodable {
    /// 当前主页主体用户。
    let user: GalleryUser
    /// 当前用户关注的人数。
    let followingNum: Int
    /// 当前用户的粉丝人数。
    let followerNum: Int
    /// 当前登录用户是否已关注该用户。
    let following: Bool
    /// 当前登录用户是否被该用户关注。
    let follower: Bool
    /// 该资料页是否属于当前登录用户自己。
    let own: Bool
}

/// “我的”页子列表的加载状态。
///
/// 与话廊、日程模块类似，这里把“空闲 / 加载中 / 已加载 / 失败”收敛成一个枚举，
/// 方便列表页统一驱动空态、错误态和 loading 态。
enum MineLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 粉丝、关注、帖子列表共用的分页状态。
///
/// 关注列表、粉丝列表和帖子列表虽然元素类型不同，但分页语义完全一致，
/// 因此抽成一个泛型状态结构统一复用。
struct MinePagedState<Item> {
    /// 当前已加载的列表项。
    var items: [Item] = []
    /// 列表整体加载状态。
    var status: MineLoadStatus = .idle
    /// 下一页页码。首页统一从 `0` 开始请求。
    var nextPage = 0
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 后端是否还有更多数据；为 `false` 时不再触发分页。
    var canLoadMore = true
}

extension MinePagedState: PagedItemsState {}
