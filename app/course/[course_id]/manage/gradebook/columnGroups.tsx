"use client";

import { toaster } from "@/components/ui/toaster";
import { useGradebookColumnGroups, useGradebookColumns, useGradebookController } from "@/hooks/useGradebook";
import { createClient } from "@/utils/supabase/client";
import {
  Box,
  Button,
  Dialog,
  HStack,
  Icon,
  IconButton,
  Input,
  NativeSelect,
  Portal,
  Text,
  VStack
} from "@chakra-ui/react";
import { useCallback, useMemo, useState } from "react";
import { LuArrowLeft, LuArrowRight, LuFolderTree, LuTrash2 } from "react-icons/lu";

// Column groups are edited only through the RPCs in 20260924233000_gradebook_column_group_crud.sql,
// which keep each group's columns contiguous and never change membership on a reorder.

const NEW_GROUP = "new";
const NO_GROUP = "none";

/** refetchAll refuses to run twice within 3s; two quick edits should still both land. */
async function refetchSoon(controller: { refetchAll: () => Promise<void> }) {
  try {
    await controller.refetchAll();
  } catch {
    await new Promise((resolve) => setTimeout(resolve, 3000));
    await controller.refetchAll().catch(() => undefined);
  }
}

/** Runs a group RPC, then refetches groups and columns so the table redraws from the new rows. */
function useGroupMutation() {
  const supabase = useMemo(() => createClient(), []);
  const gradebookController = useGradebookController();
  const [pending, setPending] = useState(false);

  const run = useCallback(
    async (
      successTitle: string,
      call: (client: typeof supabase) => PromiseLike<{ error: { message: string } | null }>
    ): Promise<boolean> => {
      setPending(true);
      try {
        const { error } = await call(supabase);
        if (error) throw new Error(error.message);
        // Group rows are not broadcast over realtime, so refetch them explicitly. Columns are,
        // but refetching here means the table is right as soon as the toast shows.
        await Promise.all([
          refetchSoon(gradebookController.gradebook_column_groups),
          refetchSoon(gradebookController.gradebook_columns)
        ]);
        toaster.create({ title: successTitle, type: "success" });
        return true;
      } catch (error) {
        toaster.create({
          title: "Column group change failed",
          description: error instanceof Error ? error.message : "An unexpected error occurred",
          type: "error"
        });
        return false;
      } finally {
        setPending(false);
      }
    },
    [supabase, gradebookController]
  );

  return { run, pending };
}

/** Dialog opened from a column's options menu: put the column in a group, a new group, or none. */
export function ChangeColumnGroupDialog({
  columnId,
  open,
  onClose
}: {
  columnId: number;
  open: boolean;
  onClose: () => void;
}) {
  const columns = useGradebookColumns();
  const groups = useGradebookColumnGroups();
  const column = columns.find((c) => c.id === columnId);
  const sortedGroups = useMemo(() => [...groups].sort((a, b) => a.sort_order - b.sort_order), [groups]);
  const [choice, setChoice] = useState<string>(column?.group_id ? String(column.group_id) : NO_GROUP);
  const [newName, setNewName] = useState("");
  const { run, pending } = useGroupMutation();

  const save = async () => {
    let ok: boolean;
    if (choice === NEW_GROUP) {
      ok = await run(`Created group "${newName.trim()}"`, (client) =>
        client.rpc("gradebook_column_group_create", { p_column_id: columnId, p_name: newName })
      );
    } else {
      const groupId = choice === NO_GROUP ? null : Number(choice);
      ok = await run(groupId === null ? "Column removed from its group" : "Column moved to group", (client) =>
        // The generated type marks p_group_id as number, but the function takes NULL for "no group".
        client.rpc("gradebook_column_set_group", { p_column_id: columnId, p_group_id: groupId as number })
      );
    }
    if (ok) onClose();
  };

  return (
    <Dialog.Root open={open} onOpenChange={(d) => !d.open && onClose()} placement="center" lazyMount unmountOnExit>
      <Portal>
        <Dialog.Backdrop />
        <Dialog.Positioner>
          <Dialog.Content>
            <Dialog.Header>
              <Dialog.Title>Change group for &ldquo;{column?.name}&rdquo;</Dialog.Title>
            </Dialog.Header>
            <Dialog.Body>
              <VStack align="stretch" gap={3}>
                <NativeSelect.Root>
                  <NativeSelect.Field
                    aria-label="Column group"
                    value={choice}
                    onChange={(e) => setChoice(e.target.value)}
                  >
                    <option value={NO_GROUP}>No group</option>
                    {sortedGroups.map((g) => (
                      <option key={g.id} value={String(g.id)}>
                        {g.name}
                      </option>
                    ))}
                    <option value={NEW_GROUP}>New group…</option>
                  </NativeSelect.Field>
                  <NativeSelect.Indicator />
                </NativeSelect.Root>
                {choice === NEW_GROUP && (
                  <Input
                    aria-label="New group name"
                    placeholder="Group name"
                    value={newName}
                    onChange={(e) => setNewName(e.target.value)}
                  />
                )}
                <Text fontSize="sm" color="fg.muted">
                  Joining a group places the column after that group&apos;s last column. Leaving one places it just
                  after the group.
                </Text>
              </VStack>
            </Dialog.Body>
            <Dialog.Footer>
              <Button variant="outline" onClick={onClose}>
                Cancel
              </Button>
              <Button
                colorPalette="green"
                onClick={save}
                loading={pending}
                disabled={choice === NEW_GROUP && newName.trim() === ""}
              >
                Save
              </Button>
            </Dialog.Footer>
          </Dialog.Content>
        </Dialog.Positioner>
      </Portal>
    </Dialog.Root>
  );
}

function GroupRow({ group, memberCount }: { group: { id: number; name: string }; memberCount: number }) {
  const [name, setName] = useState(group.name);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const { run, pending } = useGroupMutation();
  const dirty = name.trim() !== group.name && name.trim() !== "";

  return (
    <HStack gap={2} data-testid={`column-group-${group.id}`}>
      <Input
        size="sm"
        aria-label={`Name of group ${group.name}`}
        value={name}
        onChange={(e) => setName(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && dirty) {
            void run(`Renamed group to "${name.trim()}"`, (client) =>
              client.rpc("gradebook_column_group_rename", { p_group_id: group.id, p_name: name })
            );
          }
        }}
      />
      <Text fontSize="xs" color="fg.muted" whiteSpace="nowrap">
        {memberCount} col{memberCount === 1 ? "" : "s"}
      </Text>
      <Button
        size="xs"
        variant="subtle"
        disabled={!dirty || pending}
        onClick={() =>
          run(`Renamed group to "${name.trim()}"`, (client) =>
            client.rpc("gradebook_column_group_rename", { p_group_id: group.id, p_name: name })
          )
        }
      >
        Rename
      </Button>
      <IconButton
        size="xs"
        variant="ghost"
        aria-label={`Move group ${group.name} left`}
        disabled={pending}
        onClick={() =>
          run(`Moved "${group.name}" left`, (client) =>
            client.rpc("gradebook_column_group_move", { p_group_id: group.id, p_direction: -1 })
          )
        }
      >
        <Icon as={LuArrowLeft} />
      </IconButton>
      <IconButton
        size="xs"
        variant="ghost"
        aria-label={`Move group ${group.name} right`}
        disabled={pending}
        onClick={() =>
          run(`Moved "${group.name}" right`, (client) =>
            client.rpc("gradebook_column_group_move", { p_group_id: group.id, p_direction: 1 })
          )
        }
      >
        <Icon as={LuArrowRight} />
      </IconButton>
      {confirmingDelete ? (
        <Button
          size="xs"
          colorPalette="red"
          disabled={pending}
          onClick={() =>
            run(`Deleted group "${group.name}"`, (client) =>
              client.rpc("gradebook_column_group_delete", { p_group_id: group.id })
            )
          }
        >
          Confirm delete
        </Button>
      ) : (
        <IconButton
          size="xs"
          variant="ghost"
          colorPalette="red"
          aria-label={`Delete group ${group.name}`}
          onClick={() => setConfirmingDelete(true)}
        >
          <Icon as={LuTrash2} />
        </IconButton>
      )}
    </HStack>
  );
}

/** Toolbar dialog: every group in the gradebook, left to right, with rename / move / delete. */
export function ManageColumnGroupsDialog() {
  const [open, setOpen] = useState(false);
  const groups = useGradebookColumnGroups();
  const columns = useGradebookColumns();
  const sortedGroups = useMemo(() => [...groups].sort((a, b) => a.sort_order - b.sort_order), [groups]);
  const memberCounts = useMemo(() => {
    const counts = new Map<number, number>();
    columns.forEach((c) => {
      if (c.group_id !== null) counts.set(c.group_id, (counts.get(c.group_id) ?? 0) + 1);
    });
    return counts;
  }, [columns]);

  return (
    <Dialog.Root open={open} onOpenChange={(d) => setOpen(d.open)} placement="center" size="lg" lazyMount unmountOnExit>
      <Dialog.Trigger asChild>
        <Button variant="surface" size="sm">
          <Icon as={LuFolderTree} mr={2} /> Column Groups
        </Button>
      </Dialog.Trigger>
      <Portal>
        <Dialog.Backdrop />
        <Dialog.Positioner>
          <Dialog.Content>
            <Dialog.Header>
              <Dialog.Title>Column Groups</Dialog.Title>
            </Dialog.Header>
            <Dialog.Body>
              <VStack align="stretch" gap={2}>
                <Text fontSize="sm" color="fg.muted">
                  Groups are listed left to right. Moving a group moves all of its columns together; deleting a group
                  keeps its columns and grades and leaves them ungrouped. To create a group or move a column between
                  groups, use &ldquo;Change group&rdquo; in that column&apos;s options menu.
                </Text>
                {sortedGroups.length === 0 && <Text>This gradebook has no column groups yet.</Text>}
                {sortedGroups.map((g) => (
                  // Keyed on the name too, so the input resets after a rename lands.
                  <Box key={`${g.id}-${g.name}`}>
                    <GroupRow group={g} memberCount={memberCounts.get(g.id) ?? 0} />
                  </Box>
                ))}
              </VStack>
            </Dialog.Body>
            <Dialog.Footer>
              <Button variant="outline" onClick={() => setOpen(false)}>
                Done
              </Button>
            </Dialog.Footer>
          </Dialog.Content>
        </Dialog.Positioner>
      </Portal>
    </Dialog.Root>
  );
}
