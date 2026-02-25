--- /dev/null
+++ /Users/rowe/Software/FPGA/Atari7800_AstroCart/TASKLIST.md
@@ -0,0 +1,33 @@
+# AstroCart Development Tasklist
+
+## Phase 1: Foundation & Safety (Current)
+
+### 1. Safe Startup State
+- [ ] **Disable Auto-Load**: Modify `top.v` to start in `SD_IDLE` state.
+- [ ] **Verify**: System should boot to Menu (BRAM) and stay there. LEDs should indicate "Idle".
+
+### 2. 32KB ROM Support (The "Choplifter" Test)
+- [ ] **Implement Offset Logic**:
+    - 48KB Games: Load to PSRAM `0x000000` (Map to `$4000`).
+    - 32KB Games: Load to PSRAM `0x004000` (Map to `$8000`).
+- [ ] **Mirroring (Optional but Recommended)**:
+    - For 32KB games, write the data to *both* `0x000000` and `0x004000` to simulate hardware mirroring, or just ensure the loader places it correctly for the reset vector.
+
+### 3. Command Protocol Definition
+- [ ] **Define Register Interface**:
+    - **Write $2200**: Command Register.
+        - `0xA5`: Handover (Switch to Game).
+        - `0x80 + ID`: Load Game ID (Bit 7 = Load Flag).
+    - **Read Status**: **ABANDONED** due to ROM conflict risk. Use Timer in Menu.
+
+### 4. Menu Integration
+- [ ] **Update Menu**:
+    - Remove status polling.
+    - Implement "Wait Loop" (e.g., 60 frames) after triggering load.
+    - Implement "Handover Trigger" after wait.
+
+## Phase 2: Dynamic Loading (Future)
+- [ ] Parse SD Card Directory.
+- [ ] Populate Menu from File List.
+```

### 2. New File: TEST_PLAN.md

This defines how we verify the changes.

```markdown
--- /dev/null
+++ /Users/rowe/Software/FPGA/Atari7800_AstroCart/TEST_PLAN.md
@@ -0,0 +1,38 @@
+# AstroCart Test Plan
+
+## Test 1: Idle Boot
+**Objective:** Ensure FPGA does not overwrite PSRAM or steal bus on boot.
+1. Flash FPGA with new core (Auto-load disabled).
+2. Power on.
+3. **Expectation:**
+    - Menu loads and runs.
+    - LED[0] (Bus Drive) flickers (Menu running).
+    - LED[4] (Load Complete) is OFF (or indicates Idle).
+    - Game does *not* start automatically.
+
+## Test 2: 32KB Offset Loading (Choplifter)
+**Objective:** Verify 32KB games are mapped correctly to `$8000`.
+1. Hardcode loader to load Slot 1 (`Choplifter`, 32KB) to offset `0x004000`.
+2. Trigger load via Menu (or temporary auto-load for this specific test).
+3. **Expectation:**
+    - Game boots.
+    - Graphics are correct (verifies data alignment).
+    - **Failure Condition:** If screen is black or crashes immediately, the offset is likely wrong (CPU jumping to middle of ROM).
+
+## Test 3: Menu-Driven Switching
+**Objective:** Verify full pipeline (Menu -> Load -> Wait -> Handover).
+1. Boot to Menu.
+2. Select "Astro Wing" (48KB).
+3. Press Fire.
+4. **Expectation:**
+    - Screen flashes (Menu wait loop).
+    - Game loads and runs.
+5. Reset Console.
+6. Select "Choplifter" (32KB).
+7. Press Fire.
+8. **Expectation:**
+    - Game loads and runs.
+```

<!--
[PROMPT_SUGGESTION]I approve the plan. Let's start with Task 1: Disable Auto-Load in top.v.
[PROMPT_SUGGESTION]Let's tackle Task 2: Implement the 32KB Offset Logic in top.v.
-->
