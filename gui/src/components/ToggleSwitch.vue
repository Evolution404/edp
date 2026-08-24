<script setup lang="ts">
defineProps<{
  modelValue: boolean;
  disabled?: boolean;
  label: string;
  description?: string;
}>();
const emit = defineEmits<{ "update:modelValue": [value: boolean] }>();
</script>

<template>
  <label class="toggle-row" :class="{ disabled }">
    <span class="toggle-copy">
      <span class="toggle-label">{{ label }}</span>
      <span v-if="description" class="toggle-description">{{ description }}</span>
    </span>
    <span class="switch-control">
      <input
        type="checkbox"
        :checked="modelValue"
        :disabled="disabled"
        :aria-label="label"
        @change="emit('update:modelValue', ($event.target as HTMLInputElement).checked)"
      />
      <span class="switch-track"><span class="switch-thumb"></span></span>
    </span>
  </label>
</template>
