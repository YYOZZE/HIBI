# 思维节点（Mind Node）技术说明

## 1. 概述

思维节点是希比-2024 中的无限白板功能：以项目为单位，每个项目对应一块可平移、缩放的白板画布，用户可在画布上放置**方块**、用**连线**连接方块，用于梳理思路（类似 Milanote / 思维导图）。

- **入口**：底部导航「思维」→ 思维节点列表 → 点击项目进入白板。
- **数据**：项目与画布内容持久化在本地（`path_provider` 应用文档目录下的 `hibi_mind_nodes.json`）。

---

## 2. 功能规格

### 2.1 白板画布

- **坐标系**：画布为 **120000×120000** 逻辑像素，可平移、缩放。
- **默认视图**：进入白板时，视口**聚焦画布中央**（首帧延后构建后，第二帧再根据视口尺寸设置平移使画布中心对准视口中心，避免新建项目放方块后点总览方块“消失”）。
- **平移**：在白板空白处点击并拖动可平移整个画布；点击方块并拖动则只移动该方块（全平台按下即拖，无长按延迟）。
- **缩放**：支持 **25%～300%**；**电脑端**滚轮在**指针位置**为原点缩放；**移动端**双指捏合采用**以双指中点为支点**的缩放：手势开始时双指中点下的画布点，在缩放过程中始终停留在当前双指中点下（`canvasUnderFingers = (centerStart - panStart) / scaleStart`，更新后 `pan = center - scale * canvasUnderFingers`），避免「双指中间元素飞走」。屏幕下方中间显示当前缩放百分比。
- **总览**：点击左侧「总览」时，将白板缩放设为 **100%**，并将**聚焦位置移到画布中央**（视口中心对准画布中心）。
- **全屏与安全区**：白板**无 AppBar**（栏高为 0），顶部仅浮动显示返回键与项目名（`Positioned(top: 0) + SafeArea`），不占画布高度；系统栏透明由 `AnnotatedRegion<SystemUiOverlayStyle>` 设置；内容用 `SafeArea(top: true, bottom: false, left: false, right: false)` 包一层，兼容异形屏/刘海屏。
- **横屏与上下居中**：左右工具栏用 `LayoutBuilder` + `SingleChildScrollView` + `ConstrainedBox(minHeight: constraints.maxHeight)` + `Center` 包裹：`minHeight` 至少撑满视口高度，`Center` 把工具块垂直居中；内容超出视口时仍可滚动，避免 BOTTOM OVERFLOWED 黄条。
- **背景**：与 App 全局一致，整页使用 **`xhb-image/3.png`** + **与 FrostedBackground 相同的虚化**（`blurSigma: 15`）+ 深色蒙层（`Colors.black.withOpacity(0.25)`），画布区域无单独背景层，透出整页背景。上方栏、左右工具栏与方块透明/半透明透出背景；无图时回退为深色。缩放百分比条为半透明黑衬底。
- **网格**：在画布内用 `_GridPainter` 按**视口可见区域实时绘制**（只画当前视野 + 800 逻辑像素边距内的点），步长 24、点半径 2，颜色 `outline.withOpacity(0.26)`（拖放高亮时 `primary.withOpacity(0.32)`，由视口级 DragTarget 的 `_dragOverCanvas` 驱动），不参与命中；随画布缩放，大画布下保持流畅。
- **拖放接住**：整块画布（含总览、任意缩放）均可拖出并放置方块/连线。采用**视口级 DragTarget**：在白板区域 Stack 内与 Listener 同级设 `Positioned.fill(DragTarget)`，始终铺满视口，松手在视口内即接住；落点通过 `_viewportKey` + `_screenToCanvas` 转为画布坐标。工具栏「方块」「连线」的 `Draggable` 另设 `onDragEnd`，用 `_isDropInViewport(details.offset)` 判断落点是否在视口内，若在则调用 `_onDropFromTool`，作为双保险。画布内为 `ClipRect` → `OverflowBox(min/max 120000)` → `Transform` → `SizedBox(画布尺寸)` → `Stack`（白板底、网格、连线、方块）；网格可见区域用 `_viewportKey` 取视口尺寸计算，不依赖画布内 DragTarget 命中，保证总览下也能稳定放置且流畅加载。
- **边界与元素限制**：画布逻辑尺寸 **120000×120000**（约 20 倍于原 6000）；平移 `_pan` 限制在 `_clampPan()` 内。方块、连线端点与控制点均限制在画布内；加载时 `_clampAllItemsToCanvas()` 校正旧数据。

### 2.2 方块（Block）

- **创建**：从左侧工具栏将「方块」拖拽到白板上松手，在落点生成一个方块。
- **比例**：宽 220 逻辑像素；**高度默认单行**（50 逻辑像素），当字数超过一行自动增高，多行时按文字高度扩展；文字在方块内**上下居中**。
- **内容**：方块内可输入、编辑文字，多行，自动保存。
- **标记颜色**：可在文字前显示一小圆点，默认无颜色；选中方块后右侧**方块功能栏**中「颜色」可选：透明（不显示）、红、蓝、黄。颜色选择**默认不显示**，点击「颜色」按钮后在其旁边**扩展一小栏**（四色圆点），点圆点即选色，再点「颜色」可收起；切换选中其他方块时颜色栏自动收起。
- **提醒**：选中方块后右侧栏「提醒」可设置**开始时间**与**结束时间**（与日程一致的开始/结束时间选择界面）；设置后自动**同步到日程功能**，在日程页可见并编辑；清除提醒会同时移除日程中的对应项。数据字段：`reminderStartTimeMs`、`reminderEndTimeMs`（毫秒时间戳）。
- **已完成**：选中方块后右侧栏「已完成」可勾选；勾选后方块内文字变灰并加删除线。
- **移动**：**桌面**：点击白板空白处拖动＝平移整个画布，点击方块并拖动＝只移动该方块；**移动端**：长按方块约 0.5 秒后可拖动该方块，拖动白板空白处平移画布。**方块与方块不重叠**：拖动到与另一方块重叠时，会吸附到该方块的**最近边**（上下左右），且**边与边中点对齐**（如 A 在下、B 在上时，A 的上边中点与 B 的下边中点对齐），两吸附边之间留 **0 逻辑像素**间隙（`_blockSnapGap`，贴边无隙）；由 `_snapBlockToOthers` 在 `onDragUpdate` 与 `_moveBlockTo` 中统一处理。**拖动时**：方块**实时跟随指针**移动（直接更新方块位置并重绘），松手即落点，无「先 ghost 再跳转」的割裂感。
- **删除**：长按拖动方块到左侧「删除」按钮松手即可删除。

### 2.3 连线（Line）

- **创建**：方式一，从左侧工具栏将「连线」拖拽到白板任意位置松手，在该落点生成**一根连线**（仅线，不带方块）；方式二，选择「连线」后依次点击两个方块，即生成一条连接两点的连线。
- **形态**：一条**带三个控制点的连线**，**默认直线**（控制点=两端中点）：
  - **起点**（第一个点）：可挂到方块或为自由端点；拖拽到任意方块上松手即**吸附**（fromId 更新）。
  - **终点**（第三个点）：可挂到方块或为自由端点；拖拽到任意方块上松手即**吸附**（toId 更新）。
  - **中间点**（第二个点）：**仅当用户拖拽中间点**时才变为曲线（贝塞尔控制点）。一旦改过形状，**拖动所连方块拉伸连线时仍保持曲线**，不再自动变回直线；未改过形状的连线在端点移动或线体整体移动时保持直线（控制点=中点）。
- **绘制**：**白色**连线（约 92% 不透明度），线宽 **1.35** 逻辑像素；二次贝塞尔曲线。**默认仅终点箭头**；起点箭头、终点箭头、实线/虚线可在选中后通过右侧工具栏分别开关（虚线为 **6px 段 + 3px 空**）。仅**当前选中的连线**显示三个可拖拽小圆点（**视觉半径 3**，命中半径仍 **10** 保证好操作）。箭头翼长 **8**（原 12），线体在箭头根部缩短 `_arrowLen`。**贴边**：当端点挂在方块上时，连线**只在方块外侧**绘制——用 `_rayExitRect(rect.deflate(kLineEdgeInset), ...)`（`kLineEdgeInset = 1.5`）取射线与方块内侧交点，线头/箭头略伸入边界以消除可见间隙；线体在箭头**根部**结束（路径终点/起点相对 tip 缩短 `_arrowLen`），箭头尖贴方块边。
- **选中**：点击连线**任意位置**（不限于三个点）即选中该连线（`_selectedId` 为该线 id），并显示右侧连线工具栏；点击三个点之一则同时进入拖拽该点。**仅当连线两端均未接方块时**，可拖拽**线体**整体移动该连线（`_draggingLineBodyId`，按 delta 更新 fromX/Y、toX/Y，控制点重置为新的中点以保持直线）；**拖线体到左侧删除按钮松手**也会删除该连线（`onPointerUp` 检测松手位置是否在删除按钮 rect 内）。
- **吸附**：端点拖到某方块内松手时，该端点吸附到该方块（连线 fromId/toId 更新；自由端点用 fromX/Y、toX/Y 存储）。
- **删除**：① 长按连线中点拖到左侧「删除」松手；② **拖动连线任意一点（起点/中点/终点）或线体到左侧「删除」按钮松手**，则删除该连线。右侧连线栏无删除键。

### 2.4 工具栏（左侧）

- **总览**：点击后白板缩放为 100%，并将视口聚焦到画布中央。总览或任意缩放下，从工具栏拖出方块/连线到当前视口内松手均可正常放置（由视口级接住逻辑保证）。
- **方块**：从工具栏拖拽到白板任意位置松手，在该落点放置一个方块；也可点击进入其他模式。
- **连线**：从工具栏拖拽到白板任意位置松手，在该落点放置**一根连线**（仅线）；也可点击进入「连线」模式，再点两个方块创建连线；选中连线时可拖三点点调整。
- **删除**：作为拖放目标，将白板上的方块或连线长按拖到本按钮松手即可删除；点击则进入「删除」模式，点画布上元素删除。连线选中后，**拖动连线任意点到本按钮松手**也会删除该连线（通过 `onPointerUp` 检测松手位置是否在本按钮 rect 内）。

### 2.5 工具栏（右侧，选中连线时显示）

样式与左侧一致（Card + 竖向按钮）。**仅三个功能**（无「删除」）：

- **左箭头**：切换当前连线**起点**是否显示箭头（`line.startArrow`）。
- **虚线**：切换当前连线**实线/虚线**（`line.isDashed`）。
- **右箭头**：切换当前连线**终点**是否显示箭头（`line.endArrow`）。

删除连线仅通过左侧「删除」拖入或拖拽连线端点/线体到左侧删除键。**选中态**：`_ToolButton` 选中时背景 `c.withOpacity(0.4)`、图标与文字用 `colorScheme.onPrimary`，提高对比度便于辨认。

### 2.6 工具栏（右侧，选中方块时显示）

与连线栏同风格（Card + 竖向按钮）。三个功能：

- **颜色**：在方块文字前显示圆形标记（`block.dotColor`：null、'red'、'blue'、'yellow'）。**默认只显示「颜色」按钮**；点击该按钮后在其**旁边扩展一小栏**，显示四色圆点（透明、红、蓝、黄），点圆点即选色；再点「颜色」按钮可收起颜色栏。切换选中其他方块或点击画布空白/连线时，颜色栏自动收起（`_blockColorPickerExpandedForId` 随选中变化重置）。
- **提醒**：点击后弹出「开始」「结束」时间选择（与日程编辑页一致的月日 时:分 格式）；确定后写入 `block.reminderStartTimeMs`/`block.reminderEndTimeMs`，并同步到日程存储（`ScheduleEventStore`），日程页可查看/编辑；支持「清除提醒」移除时间并删除日程中的对应事件。
- **已完成**：切换 `block.completed`；为 true 时方块内文字变灰并加删除线。

---

## 3. 数据模型（简要）

- **MindNode**：项目，含 id、title、essence、canvasItems、updatedAt。
- **CanvasItem** 子类：
  - **CanvasBlock**：id, x, y, width, height, text；**dotColor**（null/red/blue/yellow，文字前圆点）、**reminderStartTimeMs**/**reminderEndTimeMs**（提醒开始/结束时间毫秒时间戳，与日程同步）、**completed**（文字变灰+删除线）。
  - **CanvasLine**：id, fromId?, toId?, fromX?, fromY?, toX?, toY?, controlX?, controlY?, **startArrow**（默认 false）, **endArrow**（默认 true）, **isDashed**（默认 false）。fromId/toId 为 null 时为自由端点；默认仅终点箭头，起点箭头可由右侧工具栏开启。
  - （兼容旧数据：CanvasNote、CanvasColumn。）

连线端点通过 fromId / toId 指向方块（或笔记/栏目）的 id，或为自由端点（fromId/toId 为 null，用 fromX/Y、toX/Y）。controlX/controlY 为 null 时表示直线（绘制时用两端中点）；仅当用户拖拽中间点后才有值，此时为贝塞尔控制点。**已设过控制点的连线**在方块移动时不再置 null，保持曲线；未设过的连线在端点松手或线体整体移动时置 null 保持直线。

---

## 4. 实现要点

- **从工具栏拖到白板**：左侧「方块」为 `Draggable<String>(data: 'block', onDragEnd: ...)`，「连线」为 `Draggable<String>(data: 'line', onDragEnd: ...)`。**接住方式**：工具栏拖出的 `'block'`/`'line'` **仅由** `Draggable.onDragEnd` 接住（`_isDropInViewport(details.offset)` 时调用 `_onDropFromTool`），视口 `DragTarget` 的 `onWillAcceptWithDetails` 对 `'block'`/`'line'` 返回 false，避免与 onDragEnd 双路重复添加；DragTarget 仅接住画布上方块移动落点（data 为 block.id）并调用 `_onDropFromTool` → `_moveBlockTo`。画布内为 `ClipRect` → `OverflowBox(120000)` → `Transform` → `SizedBox(画布尺寸)` → `Stack`（白板底、网格、连线、方块），无画布内 DragTarget；网格可见区域由 `_viewportKey` 取视口尺寸计算，高亮由视口 DragTarget 的 builder 里 `addPostFrameCallback` 更新 `_dragOverCanvas`。落点处分别 `_addBlockAt`、`_addLineAt`（连线仅在落点创建一根线，两端为自由端点）。
- **拖到删除**：白板上的方块为 `Draggable<String>(data: block.id)`（全平台按下即拖），连线在中点处叠加 `LongPressDraggable<String>(data: line.id)` 的透明区域；左侧「删除」为 `DragTarget<String>`，仅接受画布元素 id（不接受 `'block'`/`'line'` 字面量），`onAccept` 调用 `_deleteItem(id)`。
- **缩放范围与原点**：`_minScale = 0.25`，`_maxScale = 3.0`。**滚轮**：取 `PointerScrollEvent.localPosition` 为锚点，`anchorCanvas = _screenToCanvas(锚点)`，设 `newScale` 后 `_pan = 锚点 - anchorCanvas * newScale`，使锚点对准同一画布位置。**双指捏合**：记录手势开始时的双指中心、pan、scale；每次 move 时 `canvasUnderFingers = (centerStart - panStart) / scaleStart`，`_pan = center - _scale * canvasUnderFingers`，保证双指中点下的画布点不跑偏（支点缩放）。双指仅平移时仍用中心位移更新 `_pan`。**总览**时 `_scale = 1.0`、`_pan` 设为视口中心对准画布中心（再 `_clampPan()`）。**默认加载**时首帧设 `_firstFrameDone = true`，第二帧用视口尺寸将 `_pan` 设为画布居中并 `_clampPan()`。
- **点状网格**：`_GridPainter` 在画布 Stack 内（白板层之上），随画布缩放，步长 24、半径 2。
- **画布图层顺序（自底向上）**：① 白板（画布尺寸 `SizedBox`，透明）；② 网格（按视口可见区域实时绘制，高亮由 `_dragOverCanvas` 驱动）；③ 连线（仅绘制，`IgnorePointer`）；④ 连线中点 48×48 长按拖删；⑤ 方块。**视口层**：与画布 `Listener` 同级的 `Positioned.fill(DragTarget)` 铺满白板可视区域，用于接住从工具栏拖入的方块/连线及画布上方块的移动落点。
- **平移与边界**：`_clampPan()` 在每次 pan/scale 更新后执行，将 `_pan` 限制为可见区域不超出画布 [0,120000]×[0,120000]。方块添加/移动/拖拽、连线自由端点与控制点均 clamp 到画布内；加载时 `_clampAllItemsToCanvas()` 统一校正。
- **进入白板流畅度**：列表页进入白板前 `precacheImage` 预加载背景图；白板页 `Scaffold.backgroundColor` 为深色（`0xFF1a1a2e`）避免黑屏；首帧用 `addPostFrameCallback` 延后完整构建，先输出轻量首帧再下一帧渲染完整画布，减少卡顿。
- **方块尺寸与高度**：宽度 220，默认高度 50（单行）；`_BlockWidget` 内用 `TextPainter` 按当前文字与宽度计算所需高度，超过一行时写回 `block.height` 并 `onUpdate` 触发重建；`CanvasBlock` 默认及 `fromJson` 高度 50。文字区域用 `SizedBox(height: block.height - 16)` + `TextField(textAlignVertical: TextAlignVertical.center)` 实现上下居中。方块须用 `Positioned` 包一层且作为 Stack 直接子节点。**方块与工具栏样式**：方块为**轻微毛玻璃**——`ClipRRect` + `BackdropFilter(blur 10)` + `Color(0xFF2a2a3e).withOpacity(0.42)`，未选中时细白描边 `0.12` 不透明度，选中时主色描边 + `elevation 4`；圆角 6。
- **方块颜色栏展开/收起**：右侧方块栏颜色由 `_BlockColorRow` 实现；状态 `_blockColorPickerExpandedForId` 为当前展开颜色栏的方块 id（null 表示收起）。任何会改变 `_selectedId` 的操作（点其他方块、点连线、点空白、删除等）均将 `_blockColorPickerExpandedForId` 置 null，保证切换选中时颜色栏收起。
- **画布平移与方块拖动**：全平台方块均用 `Draggable`（按下即拖，无长按延迟）；点击白板空白处由 Listener 单指平移 + GestureDetector 双指处理，点击方块时由方块消费手势。**白板 Listener** 使用 `behavior: HitTestBehavior.translucent`，保证滚轮（`onPointerSignal`）在空白处也能命中并触发缩放，同时事件继续下传不挡拖拽。**方块拖动体验**：`feedback: SizedBox.shrink()` 不显示跟随指针的幽灵，`onDragUpdate` 内将指针位置转为画布坐标后直接更新 `block.x`、`block.y`（中心对齐指针）并 `setState`，方块在画布上实时跟随移动；`onDragEnd` 时 `_saveItems()`，若松手在画布内则由 DragTarget 的 `_moveBlockTo` 再做一次落点与磁吸并保存。
- **连线贴边与箭头**：端点挂在方块（fromId/toId 非空）时，用 `_getBlockRect(id)` 取方块矩形，`_rayExitRect(rect.deflate(kLineEdgeInset), center, direction)` 求从方块中心沿曲线方向与**内侧**矩形的交点（`kLineEdgeInset = 1.5`），线头/箭头略伸入边界消除间隙；绘制与命中均使用该边缘点。拖拽时（fromOverride/toOverride 非空）该端点按自由点绘制，不贴边。
- **连线选中与三点点**：**线体命中**：`_hitTestLineStroke(canvasPos)` 对每条线按贴边后的二次贝塞尔采样 32 点，距离 ≤ 12 则命中，仅设 `_selectedId`。**三点命中**：`_hitTestLinePoint(canvasPos)` 对起点/中点/终点（贴边后端点，半径 10）命中则选中并拖点。仅当 `_selectedId == line.id` 时绘制可拖拽小圆点（视觉半径 3，命中半径 10）。连线为白色、线宽 1.35，支持 startArrow/endArrow 与 isDashed（PathMetric.extractPath 分段）。拖起点/终点松手时画布 hitTest，命中方块则更新 fromId/toId，否则 fromX/Y、toX/Y；松手在左侧删除按钮 rect 内则 `_deleteItem(_draggingLineId)`。拖控制点更新 controlX/controlY；拖起点/终点松手或方块移动时调用 `_resetLineControlToMidpoint` 将 control 置 null（保持直线）。**中点拖拽跟手**：用 `_getLineEdgePointsForControl` 取与绘制一致的贴边端点，反算 control 使曲线 t=0.5 中点落在鼠标位置。**工具栏按钮选中态**：`_ToolButton` 选中时背景 `c.withOpacity(0.4)`、前景 `colorScheme.onPrimary`。**右侧连线栏**仅左箭头、虚线、右箭头三键，无删除；删除连线仅依赖左侧删除键。

---

## 5. 文件结构

- `mind_page.dart`：思维节点列表页，入口与 FAB 新建项目。
- `mind_canvas_page.dart`：白板画布页，工具栏、画布、方块、连线、总览、缩放、拖放与连线编辑。
- `models/mind_node.dart`：项目模型。
- `models/canvas_item.dart`：CanvasBlock、CanvasLine 等。
- `services/mind_repository.dart`：本地持久化与加载。
## HBM 导入导出

- 自定义扩展名：`.hbm`，文件内容为 UTF-8 JSON。
- 文件头：`format = "hibi-mind-node"`、`version = 1`、`exportedAt`，`node` 保存单个完整 `MindNode`。
- 导入时校验文件头、版本和全部画布元素类型，并重新生成项目/元素 ID；`parentId`、`childIds`、`fromId`、`toId` 同步映射。
- Windows 安装器为当前用户注册 `.hbm` 文件关联，双击后由启动参数触发导入并打开。
