# Ledger - 轻量级记账软件设计文档

## 1. 项目概述

### 1.1 目标
开发一款基于 Go 语言的轻量级日常记账软件，具备以下特点：
- **数据易迁移**：SQLite 单文件存储，复制即可迁移
- **系统开销低**：单一二进制，无需额外服务依赖
- **Agent 友好**：CLI 命令行接口，便于 AI Agent 调用
- **Web 界面**：提供可视化查账和手动记账功能
- **多账本管理**：支持多个独立账本，隔离不同场景数据

### 1.2 适用场景
个人自用记账工具，使用公司常用分类体系。

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────┐
│                   ledger (单一二进制)                  │
├─────────────────────────────────────────────────────┤
│  CLI 入口                                            │
│  ├── ledger add <账本> --amount --category          │
│  ├── ledger list <账本> --month                     │
│  ├── ledger balance <账本>                          │
│  ├── ledger book create <名称>                      │
│  └── ledger serve --port 8080                       │
├─────────────────────────────────────────────────────┤
│  核心逻辑层 (Go)                                     │
│  ├── 记账服务 (增删改查)                              │
│  ├── 账本管理                                        │
│  └── 统计计算                                        │
├─────────────────────────────────────────────────────┤
│  数据访问层                                          │
│  └── SQLite (每个账本一个 .db 文件)                  │
├─────────────────────────────────────────────────────┤
│  Web 服务层                                          │
│  ├── REST API (HTTP 暴露)                           │
│  └── 静态资源 (嵌入的前端)                           │
└─────────────────────────────────────────────────────┘
```

### 2.2 关键设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 数据库 | SQLite | 零配置、单文件、易迁移、轻量 |
| 部署方式 | Docker | 环境隔离、分发便利 |
| 架构模式 | CLI 核心 + 内嵌 Web | 单一二进制，CLI 和 Web 共享逻辑 |
| 账本组织 | 独立数据库文件 | 完全隔离，迁移只需复制文件 |

---

## 3. 数据模型

### 3.1 全局配置

**文件路径**：`~/.ledger/config.json`

```json
{
  "default_book": "default",
  "books": [
    {"name": "default", "path": "~/.ledger/books/default.db", "created_at": "2024-01-01"},
    {"name": "旅行", "path": "~/.ledger/books/travel.db", "created_at": "2024-02-15"}
  ]
}
```

### 3.2 记账记录表

**位置**：每个账本数据库内

```sql
CREATE TABLE entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    amount REAL NOT NULL,
    category TEXT NOT NULL,
    date TEXT NOT NULL,
    note TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT
);

CREATE INDEX idx_entries_date ON entries(date);
CREATE INDEX idx_entries_category ON entries(category);
```

### 3.3 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增 |
| amount | REAL | 金额，正数=收入，负数=支出 |
| category | TEXT | 分类（见下方预设） |
| date | TEXT | 日期，格式 YYYY-MM-DD |
| note | TEXT | 备注（可选） |
| created_at | TEXT | 创建时间 |
| updated_at | TEXT | 最后修改时间 |

### 3.4 分类预设

**支出类**：
- 办公用品
- 差旅费
- 餐饮招待
- 采购
- 通讯费
- 水电物业
- 租金
- 工资薪酬
- 营销推广
- 其他支出

**收入类**：
- 销售收入
- 投资收益
- 拨款补贴
- 其他收入

---

## 4. CLI 命令设计

### 4.1 账本管理

```bash
ledger book create <名称>           # 创建新账本
ledger book list                    # 列出所有账本
ledger book delete <名称>           # 删除账本（需确认）
ledger book rename <旧名> <新名>    # 重命名账本
```

### 4.2 记账操作

```bash
ledger add [账本] --amount <金额> --category <分类> [--date <日期>] [--note <备注>]

# 示例
ledger add --amount -50 --category 餐饮招待 --note 午餐
ledger add 项目A --amount -200 --category 差旅费 --date 2024-01-15
ledger add --amount 5000 --category 销售收入 --note 产品订单
```

### 4.3 查询记录

```bash
ledger list [账本] [--month <月份>] [--category <分类>]

# 示例
ledger list
ledger list 项目A --month 2024-01
```

### 4.4 统计

```bash
ledger balance [账本] [--month <月份>]

# 输出示例
收入: ¥15,000
支出: ¥8,230
余额: ¥6,770
```

### 4.5 Web 服务

```bash
ledger serve [--port 8080] [--host 0.0.0.0]
```

---

## 5. REST API 设计

### 5.1 账本管理

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/books` | 获取账本列表 |
| POST | `/api/books` | 创建新账本 |
| DELETE | `/api/books/:name` | 删除账本 |

### 5.2 记账记录

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/entries` | 查询记录 |
| POST | `/api/entries` | 新增记录 |
| PUT | `/api/entries/:id` | 修改记录 |
| DELETE | `/api/entries/:id` | 删除记录 |

**查询参数**：
- `book`：账本名（可选，默认使用默认账本）
- `month`：月份筛选，格式 YYYY-MM（可选）
- `category`：分类筛选（可选）

**POST/PUT 请求体**：
```json
{
  "book": "default",
  "amount": -50,
  "category": "餐饮招待",
  "date": "2024-01-15",
  "note": "午餐"
}
```

### 5.3 统计

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/stats/balance` | 收支统计 |

**查询参数**：
- `book`：账本名
- `month`：月份（可选）
- `year`：年份（可选）

**响应示例**：
```json
{
  "income": 15000,
  "expense": 8230,
  "balance": 6770
}
```

### 5.4 分类

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/categories` | 获取分类列表 |

---

## 6. Web 界面设计

### 6.1 美学方向

**风格**：现代禅意风格
- 大量留白，呼吸感强
- 柔和圆角与精致阴影
- 数字/金额作为视觉焦点
- 微妙的过渡动画

### 6.2 主题系统

**亮色主题**：
- 背景：#FAFAF8（温暖米白）
- 前景：#2D2D2D（深炭灰）
- 卡片：#FFFFFF（纯白）
- 强调色：#3B82F6（优雅青蓝）

**暗色主题**：
- 背景：#18181B（深邃暗灰）
- 前景：#E4E4E7（柔和灰白）
- 卡片：#27272A（略亮深灰）
- 强调色：#60A5FA（明亮青蓝）

### 6.3 页面结构

#### 6.3.1 首页/仪表盘
- 顶部导航：Logo、账本切换、主题切换按钮
- 核心区：当前余额大字展示（等宽字体）
- 本月统计：三个卡片（收入/支出/结余）
- 近期记录：简洁列表，悬停高亮

#### 6.3.2 记账页面
- 居中卡片式表单
- 金额输入大字号，实时显示正负
- 分类标签式选择器
- 提交后优雅滑出成功提示

#### 6.3.3 记录列表
- 顶部筛选栏：月份选择器、分类下拉
- 表格设计：极简线条，悬停行高亮
- 金额列右对齐，正负数颜色区分

#### 6.3.4 统计页面
- 月度收支：柔和渐变柱状图
- 分类占比：极简环形图
- 趋势图：平滑曲线，带渐变填充

### 6.4 技术选型

| 模块 | 技术 | 理由 |
|------|------|------|
| 框架 | Vue 3 + Vite | 轻量、构建产物小 |
| 样式 | Tailwind CSS | 快速开发，主题切换支持好 |
| 图表 | Chart.js | 轻量、API 友好 |
| 字体 | 思源黑体 + JetBrains Mono | 中文排版好，数字等宽清晰 |

### 6.5 交互细节

- 主题切换：平滑过渡动画
- 卡片悬停：微妙上浮 + 阴影增强
- 记账提交：成功后卡片翻转动画
- 数字变化：计数动画效果

---

## 7. 部署方案

### 7.1 Docker

**Dockerfile 设计**：
- 基于 Alpine Linux，体积小
- 单二进制文件，无需额外依赖
- 暴露 8080 端口
- 挂载 `~/.ledger/` 目录实现数据持久化

**运行命令**：
```bash
docker run -d \
  -p 8080:8080 \
  -v ~/.ledger:/root/.ledger \
  ledger:latest \
  ledger serve --host 0.0.0.0 --port 8080
```

**CLI 调用（Docker 内）**：
```bash
docker exec <container_id> ledger add --amount -50 --category 餐饮招待
```

### 7.2 直接运行

```bash
# 开发模式
go run main.go serve

# 构建后运行
go build -o ledger .
./ledger serve --port 8080
```

---

## 8. 目录结构

```
ledger/
├── cmd/
│   └── ledger/
│       └── main.go              # CLI 入口
├── internal/
│   ├── app/
│   │   └── app.go               # 应用初始化
│   ├── book/
│   │   └── manager.go           # 账本管理
│   ├── entry/
│   │   ├── service.go           # 记账服务
│   │   └── repository.go        # 数据访问
│   ├── stats/
│   │   └── calculator.go        # 统计计算
│   ├── server/
│   │   ├── api.go               # REST API
│   │   └── web.go               # Web 静态资源
│   └── storage/
│       └── sqlite.go            # SQLite 封装
├── web/
│   ├── index.html
│   ├── src/
│   │   ├── main.js
│   │   ├── App.vue
│   │   ├── components/
│   │   ├── views/
│   │   └── api/
│   ├── vite.config.js
│   └── package.json
├── Dockerfile
├── go.mod
└── go.sum
```

---

## 9. 安全性

- 本地运行，无用户认证需求
- 数据库文件权限控制（600）
- API 无认证，仅本地访问
- Docker 运行时非 root 用户

---

## 10. 数据迁移

- 账本数据：直接复制 `.db` 文件
- 配置文件：复制 `config.json`
- 完整备份：复制整个 `~/.ledger/` 目录

---

## 11. 版本计划

### v1.0 核心功能
- CLI 记账和查询
- 多账本管理
- SQLite 存储
- REST API

### v1.1 Web 界面
- 记账页面
- 记录列表
- 统计图表
- 主题切换

### v1.2 部署优化
- Docker 支持
- 数据导入导出