import DefaultTheme from 'vitepress/theme'
import mediumZoom from 'medium-zoom'
import { onMounted, watch, nextTick } from 'vue'
import { useRoute } from 'vitepress'
import './style.css'

let zoom: ReturnType<typeof mediumZoom> | null = null

export default {
  ...DefaultTheme,
  setup() {
    const route = useRoute()
    const initZoom = () => {
      if (zoom) zoom.detach()
      zoom = mediumZoom('.vp-doc img', { background: 'rgba(0,0,0,0.8)', margin: 200 })
    }
    onMounted(() => initZoom())
    watch(() => route.path, () => nextTick(() => initZoom()))
  },
  enhanceApp({ router }: { router: any }) {
    if (typeof window === 'undefined') return
    router.onBeforeRouteChange = (to: string) => {
      if (to === '/bridge-lite/' || to === '/bridge-lite') {
        window.location.href = to
        return false
      }
    }
  },
}
