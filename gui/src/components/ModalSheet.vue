<script setup lang="ts">
defineProps<{ title: string; description?: string; closeLabel?: string }>();
const emit = defineEmits<{ close: [] }>();
</script>

<template>
  <div class="sheet-backdrop" role="presentation" @mousedown.self="emit('close')">
    <section class="sheet" role="dialog" aria-modal="true" :aria-label="title">
      <header class="sheet-header">
        <div>
          <h2>{{ title }}</h2>
          <p v-if="description">{{ description }}</p>
        </div>
        <button class="icon-button" :aria-label="closeLabel ?? '关闭'" @click="emit('close')">×</button>
      </header>
      <div class="sheet-body"><slot /></div>
      <footer v-if="$slots.footer" class="sheet-footer"><slot name="footer" /></footer>
    </section>
  </div>
</template>
