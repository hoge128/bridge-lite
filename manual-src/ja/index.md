---
layout: page
---

<script setup>
import { onMounted } from 'vue'
import { useRouter } from 'vitepress'
const { go } = useRouter()
onMounted(() => go('/bridge-lite/manual/ja/introduction'))
</script>
