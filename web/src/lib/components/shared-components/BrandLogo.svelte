<script lang="ts">
  import type { Size } from '@immich/ui';
  import { tv } from 'tailwind-variants';

  type Props = {
    size?: Size;
    variant?: 'icon' | 'inline';
    class?: string;
  };

  let { variant = 'icon', size = 'medium', class: className }: Props = $props();

  const styles = tv({
    base: 'inline-flex shrink-0 items-center gap-2 text-primary',
    variants: {
      size: {
        tiny: 'h-8 text-xl',
        small: 'h-10 text-2xl',
        medium: 'h-12 text-3xl',
        large: 'h-16 text-4xl',
        giant: 'h-24 text-6xl',
      },
    },
  });
</script>

<span class={styles({ size, class: className })} role="img" aria-label="Ilyich logo">
  <img src="/ilyich-logo.png" class="aspect-square h-full rounded-[20%]" alt="" draggable="false" />
  {#if variant === 'inline'}
    <span class="font-semibold tracking-tight" aria-hidden="true">Ilyich</span>
  {/if}
</span>
