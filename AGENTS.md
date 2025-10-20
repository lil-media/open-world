# Agent Workflow & Maintenance Guide

This document defines the workflow for AI agents working on this project to ensure consistent progress tracking and documentation.

## Core Principles

1. **Always update ROADMAP.md** when completing major features or milestones
2. **Document performance changes** when optimizations are made
3. **Track known issues** that need to be addressed
4. **Maintain accurate status** of what's complete vs. in-progress
5. **Update dates** when making significant changes

## Start of Session Checklist

When beginning work on this project:

1. ✅ Read `ROADMAP.md` to understand current status
2. ✅ Check git status to see recent changes
3. ✅ Review "In Progress" and "Next Up" sections
4. ✅ Build and test current state before making changes
5. ✅ Use TodoWrite tool to plan multi-step tasks

## During Development

### When to Update ROADMAP.md

**Always update when:**
- ✅ Completing a major feature (e.g., "Metal Integration", "Frustum Culling")
- ✅ Achieving a performance milestone (e.g., hitting 60 FPS target)
- ✅ Moving from "In Progress" to "Completed"
- ✅ Identifying new blocking issues or technical debt
- ✅ Making architectural decisions that affect the roadmap

**What to update:**
- Move completed items from "In Progress" to "Completed"
- Add checkmarks [x] to completed sub-tasks
- Update "Current Performance" metrics if changed
- Add "Recent Optimizations" with dates and specific improvements
- Document "Known Issues" discovered during development
- Update phase percentages and status markers

### Performance Tracking

When making performance-related changes, document:
- **Before/After FPS** measurements
- **Specific optimization** applied (e.g., "frustum culling")
- **Impact metrics** (e.g., "90% chunk reduction", "+15% FPS")
- **Test conditions** (resolution, hardware, view distance)

Example format:
```markdown
**Recent Optimizations (YYYY-MM-DD):**
- Feature: X% improvement (before → after metrics)
- Specific change description
```

### Known Issues Section

Maintain a "Known Issues" section for:
- Performance bottlenecks not yet addressed
- Bugs that need fixing
- Technical debt
- Blocking issues for next features

## End of Session Checklist

Before ending a coding session:

1. ✅ Update ROADMAP.md with completed work
2. ✅ Commit changes with clear commit messages
3. ✅ Update "In Progress" section with current state
4. ✅ Document any new known issues discovered
5. ✅ Note next recommended steps in "Next Up"

## ROADMAP.md Structure

Maintain these key sections:

```markdown
## Current Status (Phase X - Name)

### ✅ Completed
[Bullet list of completed features]

### 🏗️ In Progress
[Current work items]

### 📋 Next Up
[Prioritized next tasks]

## Phase Breakdown

### Phase X: Name (Weeks Y-Z)

#### Week A-B: Feature Category
[Detailed breakdown with checkboxes]

**Performance Target:** [Specific metric]
**Current Performance:** ✅/⚠️/❌ [Actual metric]

**Recent Optimizations (YYYY-MM-DD):**
[Dated list of recent improvements]

**Known Issues:**
[Current blockers and problems]
```

## Git Commit Messages

Follow this format for commits:

```
Short summary (50 chars or less)

- Detailed change 1
- Detailed change 2
- Performance impact (if applicable)

Updated ROADMAP.md: [what changed in roadmap]
```

Example:
```
Implement frustum culling for chunk rendering

- Added Frustum and Plane structures to math.zig
- Integrated frustum culling into updateGpuMeshes
- Added 2-block margin to prevent false culling
- 90% chunk culling efficiency (110 → 10 chunks)
- +15% FPS improvement (100 → 114 FPS)

Updated ROADMAP.md: Marked frustum culling complete, added performance metrics
```

## Documentation Updates

### When Features Are Complete

Create or update relevant documentation:
- Add code comments for complex algorithms
- Update architecture overview if structure changes
- Document new APIs and functions
- Add usage examples for new systems

### Performance Benchmarks

When adding optimizations, include:
- Baseline measurements before changes
- Target performance goals
- Actual results achieved
- Testing methodology

## Common Patterns

### Feature Implementation Flow

1. **Plan**: Use TodoWrite tool to break down task
2. **Research**: Read existing code to understand integration points
3. **Implement**: Write code with clear comments
4. **Test**: Build and verify functionality
5. **Optimize**: Profile and improve performance
6. **Document**: Update ROADMAP.md and code comments
7. **Commit**: Clear commit message with changes

### Performance Optimization Flow

1. **Measure**: Establish baseline metrics
2. **Profile**: Identify bottlenecks
3. **Optimize**: Implement improvement
4. **Verify**: Measure impact
5. **Document**: Update ROADMAP.md with metrics
6. **Commit**: Include before/after in commit message

## Project-Specific Notes

### Current Focus (2025-10-20)

**Phase 1 Status:** Graphics & Rendering Foundation - Week 3-4 (Optimization)
- Core rendering: ✅ Complete (exceeded performance targets)
- Frustum culling: ✅ Complete
- **Next Priority:** Async mesh generation to eliminate startup stutter

### Critical Path

1. Async mesh generation (fixes 1-2 FPS startup issue)
2. GPU performance profiling (Metal Performance HUD)
3. Block interaction (ray casting)
4. Save/Load system
5. Move to Phase 2: Advanced terrain features

### Performance Targets

- **Current:** 114 FPS @ 1280x720 (M3 Pro)
- **Target:** 60 FPS @ 1080p (M1)
- **Stretch:** 120 FPS @ 1080p (M3+)

### Technical Debt

- Synchronous mesh generation blocks main thread
- No save/load system yet
- Chunk streaming is synchronous (needs thread pool)
- No LOD system for distant chunks

## Questions to Ask

Before making changes, consider:

1. **Impact**: Does this change affect the roadmap timeline?
2. **Performance**: What's the performance impact?
3. **Architecture**: Does this fit the existing architecture?
4. **Testing**: How can this be tested and verified?
5. **Documentation**: What needs to be documented?

## Example Session Flow

```
1. Start session
   └─ Read ROADMAP.md
   └─ Check git status
   └─ Build and test current state

2. Plan work
   └─ Use TodoWrite for multi-step tasks
   └─ Identify integration points

3. Implement feature
   └─ Write code with comments
   └─ Build and test incrementally

4. Verify and measure
   └─ Run performance tests
   └─ Document metrics

5. Update documentation
   └─ Update ROADMAP.md
   └─ Add code comments
   └─ Update this file if workflow changes

6. Commit changes
   └─ Clear commit message
   └─ Note roadmap updates
```

---

**Last Updated:** 2025-10-20
**Document Version:** 1.0
**Maintained By:** AI Agents working on the project
