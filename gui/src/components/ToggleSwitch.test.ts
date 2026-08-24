import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import ToggleSwitch from "./ToggleSwitch.vue";

describe("ToggleSwitch", () => {
  it("通过同一个受控值发送状态变更", async () => {
    const wrapper = mount(ToggleSwitch, {
      props: { modelValue: false, label: "自动挂载已暂停" },
    });
    await wrapper.get("input").setValue(true);
    expect(wrapper.emitted("update:modelValue")?.[0]).toEqual([true]);
  });
});
