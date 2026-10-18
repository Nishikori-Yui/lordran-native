// Unit tests run on the host stack, so the HLE entry stub does not need to switch stacks.
__asm__(".text\n.globl _dm_bigstack_enter\n_dm_bigstack_enter:\n    br x16\n");
