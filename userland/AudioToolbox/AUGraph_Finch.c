/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    AUNode node;
    AudioComponentDescription description;
    AudioUnit unit;
    AUGraph subgraph;
    Boolean isOutput;
} FinchGraphNode;

typedef struct {
    AURenderCallback callback;
    void *refCon;
} FinchRenderNotify;

struct OpaqueAUGraph {
    FinchGraphNode *nodes;
    size_t nodeCount;
    size_t nodeCapacity;
    AUNode nextNode;
    AUNodeInteraction *interactions;
    size_t interactionCount;
    size_t interactionCapacity;
    FinchRenderNotify *notifiers;
    size_t notifierCount;
    size_t notifierCapacity;
    Boolean open;
    Boolean initialized;
    Boolean running;
    Boolean ownedByParent;
};

static FinchGraphNode *
node_for(AUGraph graph, AUNode node)
{
    if (!graph)
        return NULL;
    for (size_t i = 0; i < graph->nodeCount; i++)
        if (graph->nodes[i].node == node)
            return &graph->nodes[i];
    return NULL;
}

static OSStatus
reserve_nodes(AUGraph graph)
{
    if (graph->nodeCount < graph->nodeCapacity)
        return noErr;
    size_t capacity = graph->nodeCapacity ? graph->nodeCapacity * 2 : 4;
    FinchGraphNode *nodes = realloc(graph->nodes, capacity * sizeof(*nodes));
    if (!nodes)
        return kAudio_ParamError;
    graph->nodes = nodes;
    graph->nodeCapacity = capacity;
    return noErr;
}

static OSStatus
reserve_interactions(AUGraph graph)
{
    if (graph->interactionCount < graph->interactionCapacity)
        return noErr;
    size_t capacity = graph->interactionCapacity ? graph->interactionCapacity * 2 : 8;
    AUNodeInteraction *items = realloc(graph->interactions, capacity * sizeof(*items));
    if (!items)
        return kAudio_ParamError;
    graph->interactions = items;
    graph->interactionCapacity = capacity;
    return noErr;
}

static OSStatus
reserve_notifiers(AUGraph graph)
{
    if (graph->notifierCount < graph->notifierCapacity)
        return noErr;
    size_t capacity = graph->notifierCapacity ? graph->notifierCapacity * 2 : 4;
    FinchRenderNotify *items = realloc(graph->notifiers, capacity * sizeof(*items));
    if (!items)
        return kAudio_ParamError;
    graph->notifiers = items;
    graph->notifierCapacity = capacity;
    return noErr;
}

OSStatus
NewAUGraph(AUGraph *outGraph)
{
    if (!outGraph)
        return kAudio_ParamError;
    *outGraph = calloc(1, sizeof(**outGraph));
    if (*outGraph)
        (*outGraph)->nextNode = 1;
    return *outGraph ? noErr : kAudio_ParamError;
}

static void
free_graph(AUGraph graph)
{
    if (!graph)
        return;
    if (graph->open)
        AUGraphClose(graph);
    for (size_t i = 0; i < graph->nodeCount; i++)
        if (graph->nodes[i].subgraph)
            free_graph(graph->nodes[i].subgraph);
    free(graph->nodes);
    free(graph->interactions);
    free(graph->notifiers);
    free(graph);
}

OSStatus
DisposeAUGraph(AUGraph graph)
{
    if (!graph)
        return kAudio_ParamError;
    free_graph(graph);
    return noErr;
}

OSStatus
AUGraphAddNode(AUGraph graph, const AudioComponentDescription *description, AUNode *outNode)
{
    if (!graph || !description || !outNode || graph->running)
        return kAudio_ParamError;
    AudioComponent component = AudioComponentFindNext(NULL, description);
    if (!component)
        return kAUGraphErr_InvalidAudioUnit;
    Boolean isOutput = description->componentType == kAudioUnitType_Output;
    if (isOutput)
        for (size_t i = 0; i < graph->nodeCount; i++)
            if (graph->nodes[i].isOutput)
                return kAUGraphErr_OutputNodeErr;
    OSStatus status = reserve_nodes(graph);
    if (status != noErr)
        return status;
    AUNode node = graph->nextNode++;
    graph->nodes[graph->nodeCount++] = (FinchGraphNode){.node = node, .description = *description, .isOutput = isOutput};
    *outNode = node;
    return noErr;
}

OSStatus
AUGraphRemoveNode(AUGraph graph, AUNode node)
{
    if (!graph || graph->running)
        return kAudio_ParamError;
    size_t index = 0;
    while (index < graph->nodeCount && graph->nodes[index].node != node)
        index++;
    if (index == graph->nodeCount)
        return kAUGraphErr_NodeNotFound;
    FinchGraphNode *found = &graph->nodes[index];
    if (found->unit) {
        if (graph->initialized)
            AudioUnitUninitialize(found->unit);
        AudioComponentInstanceDispose(found->unit);
    }
    if (found->subgraph)
        free_graph(found->subgraph);
    memmove(found, found + 1, (graph->nodeCount - index - 1) * sizeof(*found));
    graph->nodeCount--;
    for (size_t i = 0; i < graph->interactionCount;) {
        AUNodeInteraction *interaction = &graph->interactions[i];
        Boolean remove = interaction->nodeInteractionType == kAUNodeInteraction_Connection
            ? interaction->nodeInteraction.connection.sourceNode == node || interaction->nodeInteraction.connection.destNode == node
            : interaction->nodeInteraction.inputCallback.destNode == node;
        if (remove) {
            AUNode destNode = interaction->nodeInteractionType == kAUNodeInteraction_Connection
                ? interaction->nodeInteraction.connection.destNode : interaction->nodeInteraction.inputCallback.destNode;
            UInt32 destBus = interaction->nodeInteractionType == kAUNodeInteraction_Connection
                ? interaction->nodeInteraction.connection.destInputNumber : interaction->nodeInteraction.inputCallback.destInputNumber;
            FinchGraphNode *dest = node_for(graph, destNode);
            if (graph->open && dest && dest->unit) {
                if (interaction->nodeInteractionType == kAUNodeInteraction_Connection) {
                    AudioUnitConnection empty = {0};
                    AudioUnitSetProperty(dest->unit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input,
                        destBus, &empty, sizeof(empty));
                } else {
                    AURenderCallbackStruct empty = {0};
                    AudioUnitSetProperty(dest->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                        destBus, &empty, sizeof(empty));
                }
            }
            memmove(interaction, interaction + 1, (graph->interactionCount - i - 1) * sizeof(*interaction));
            graph->interactionCount--;
        } else {
            i++;
        }
    }
    return noErr;
}

OSStatus
AUGraphGetNodeCount(AUGraph graph, UInt32 *outCount)
{
    if (!graph || !outCount)
        return kAudio_ParamError;
    *outCount = (UInt32)graph->nodeCount;
    return noErr;
}

OSStatus
AUGraphGetIndNode(AUGraph graph, UInt32 index, AUNode *outNode)
{
    if (!graph || !outNode)
        return kAudio_ParamError;
    if (index >= graph->nodeCount)
        return kAUGraphErr_NodeNotFound;
    *outNode = graph->nodes[index].node;
    return noErr;
}

OSStatus
AUGraphNodeInfo(AUGraph graph, AUNode node, AudioComponentDescription *outDescription, AudioUnit *outUnit)
{
    FinchGraphNode *found = node_for(graph, node);
    if (!found)
        return kAUGraphErr_NodeNotFound;
    if (outDescription)
        *outDescription = found->description;
    if (outUnit)
        *outUnit = found->unit;
    return noErr;
}

OSStatus
AUGraphNewNode(AUGraph graph, const struct ComponentDescription *description, UInt32 classDataSize, const void *classData, AUNode *outNode)
{
    if (!description || classDataSize || classData)
        return kAudio_ParamError;
    AudioComponentDescription current;
    memcpy(&current, description, sizeof(current));
    return AUGraphAddNode(graph, &current, outNode);
}

OSStatus
AUGraphGetNodeInfo(AUGraph graph, AUNode node, struct ComponentDescription *description, UInt32 *classDataSize, void **classData, AudioUnit *unit)
{
    AudioComponentDescription current;
    OSStatus status = AUGraphNodeInfo(graph, node, description ? &current : NULL, unit);
    if (status != noErr)
        return status;
    if (description)
        memcpy(description, &current, sizeof(current));
    if (classDataSize)
        *classDataSize = 0;
    if (classData)
        *classData = NULL;
    return noErr;
}

OSStatus
AUGraphNewNodeSubGraph(AUGraph graph, AUNode *outNode)
{
    if (!graph || !outNode || graph->running)
        return kAudio_ParamError;
    OSStatus status = reserve_nodes(graph);
    if (status != noErr)
        return status;
    AUGraph child = NULL;
    status = NewAUGraph(&child);
    if (status != noErr)
        return status;
    child->ownedByParent = true;
    AUNode node = graph->nextNode++;
    FinchGraphNode item = {.node = node, .subgraph = child};
    graph->nodes[graph->nodeCount++] = item;
    *outNode = node;
    return noErr;
}

OSStatus
AUGraphGetNodeInfoSubGraph(const AUGraph graph, AUNode node, AUGraph *outSubgraph)
{
    FinchGraphNode *found = node_for((AUGraph)graph, node);
    if (!found || !found->subgraph)
        return kAUGraphErr_NodeNotFound;
    if (!outSubgraph)
        return kAudio_ParamError;
    *outSubgraph = found->subgraph;
    return noErr;
}

OSStatus
AUGraphIsNodeSubGraph(const AUGraph graph, AUNode node, Boolean *outFlag)
{
    FinchGraphNode *found = node_for((AUGraph)graph, node);
    if (!found)
        return kAUGraphErr_NodeNotFound;
    if (!outFlag)
        return kAudio_ParamError;
    *outFlag = found->subgraph != NULL;
    return noErr;
}

static size_t
interaction_for_input(AUGraph graph, AUNode node, UInt32 bus)
{
    for (size_t i = 0; i < graph->interactionCount; i++) {
        AUNodeInteraction *item = &graph->interactions[i];
        if (item->nodeInteractionType == kAUNodeInteraction_Connection &&
            item->nodeInteraction.connection.destNode == node && item->nodeInteraction.connection.destInputNumber == bus)
            return i;
        if (item->nodeInteractionType == kAUNodeInteraction_InputCallback &&
            item->nodeInteraction.inputCallback.destNode == node && item->nodeInteraction.inputCallback.destInputNumber == bus)
            return i;
    }
    return SIZE_MAX;
}

static OSStatus
install_interaction(AUGraph graph, const AUNodeInteraction *interaction)
{
    if (interaction->nodeInteractionType == kAUNodeInteraction_Connection) {
        const AUNodeConnection *connection = &interaction->nodeInteraction.connection;
        FinchGraphNode *source = node_for(graph, connection->sourceNode);
        FinchGraphNode *dest = node_for(graph, connection->destNode);
        if (!source || !dest || !source->unit || !dest->unit)
            return kAUGraphErr_NodeNotFound;
        AudioUnitConnection unitConnection = {source->unit, connection->sourceOutputNumber, connection->destInputNumber};
        return AudioUnitSetProperty(dest->unit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input,
                                    connection->destInputNumber, &unitConnection, sizeof(unitConnection));
    }
    if (interaction->nodeInteractionType == kAUNodeInteraction_InputCallback) {
        const AUNodeRenderCallback *callback = &interaction->nodeInteraction.inputCallback;
        FinchGraphNode *dest = node_for(graph, callback->destNode);
        if (!dest || !dest->unit)
            return kAUGraphErr_NodeNotFound;
        AURenderCallbackStruct render = callback->cback;
        return AudioUnitSetProperty(dest->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                    callback->destInputNumber, &render, sizeof(render));
    }
    return kAudio_ParamError;
}

OSStatus
AUGraphConnectNodeInput(AUGraph graph, AUNode sourceNode, UInt32 sourceBus, AUNode destNode, UInt32 destBus)
{
    if (!graph || graph->running || !node_for(graph, sourceNode) || !node_for(graph, destNode))
        return kAUGraphErr_NodeNotFound;
    if (sourceNode == destNode || interaction_for_input(graph, destNode, destBus) != SIZE_MAX)
        return kAUGraphErr_InvalidConnection;
    OSStatus status = reserve_interactions(graph);
    if (status != noErr)
        return status;
    AUNodeInteraction interaction = {.nodeInteractionType = kAUNodeInteraction_Connection,
        .nodeInteraction.connection = {sourceNode, sourceBus, destNode, destBus}};
    if (graph->open) {
        status = install_interaction(graph, &interaction);
        if (status != noErr)
            return status;
    }
    graph->interactions[graph->interactionCount++] = interaction;
    return noErr;
}

OSStatus
AUGraphSetNodeInputCallback(AUGraph graph, AUNode node, UInt32 bus, const AURenderCallbackStruct *callback)
{
    if (!graph || !callback || graph->running || !node_for(graph, node))
        return kAUGraphErr_NodeNotFound;
    size_t index = interaction_for_input(graph, node, bus);
    AUNodeInteraction interaction = {.nodeInteractionType = kAUNodeInteraction_InputCallback,
        .nodeInteraction.inputCallback = {node, bus, *callback}};
    if (graph->open && index != SIZE_MAX && graph->interactions[index].nodeInteractionType == kAUNodeInteraction_Connection) {
        AudioUnitConnection empty = {0};
        FinchGraphNode *dest = node_for(graph, node);
        AudioUnitSetProperty(dest->unit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, bus, &empty, sizeof(empty));
    }
    if (graph->open) {
        OSStatus status = install_interaction(graph, &interaction);
        if (status != noErr)
            return status;
    }
    if (index != SIZE_MAX)
        graph->interactions[index] = interaction;
    else {
        OSStatus status = reserve_interactions(graph);
        if (status != noErr)
            return status;
        graph->interactions[graph->interactionCount++] = interaction;
    }
    return noErr;
}

OSStatus
AUGraphDisconnectNodeInput(AUGraph graph, AUNode node, UInt32 bus)
{
    if (!graph || graph->running || !node_for(graph, node))
        return kAUGraphErr_NodeNotFound;
    size_t index = interaction_for_input(graph, node, bus);
    if (index == SIZE_MAX)
        return kAUGraphErr_InvalidConnection;
    if (graph->open) {
        FinchGraphNode *dest = node_for(graph, node);
        if (graph->interactions[index].nodeInteractionType == kAUNodeInteraction_Connection) {
            AudioUnitConnection empty = {0};
            OSStatus status = AudioUnitSetProperty(dest->unit, kAudioUnitProperty_MakeConnection,
                kAudioUnitScope_Input, bus, &empty, sizeof(empty));
            if (status != noErr)
                return status;
        } else {
            AURenderCallbackStruct empty = {0};
            OSStatus status = AudioUnitSetProperty(dest->unit, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, bus, &empty, sizeof(empty));
            if (status != noErr)
                return status;
        }
    }
    memmove(&graph->interactions[index], &graph->interactions[index + 1],
            (graph->interactionCount - index - 1) * sizeof(*graph->interactions));
    graph->interactionCount--;
    return noErr;
}

OSStatus
AUGraphClearConnections(AUGraph graph)
{
    if (!graph || graph->running)
        return kAudio_ParamError;
    while (graph->interactionCount) {
        AUNodeInteraction *last = &graph->interactions[graph->interactionCount - 1];
        AUNode node = last->nodeInteractionType == kAUNodeInteraction_Connection
            ? last->nodeInteraction.connection.destNode : last->nodeInteraction.inputCallback.destNode;
        UInt32 bus = last->nodeInteractionType == kAUNodeInteraction_Connection
            ? last->nodeInteraction.connection.destInputNumber : last->nodeInteraction.inputCallback.destInputNumber;
        OSStatus status = AUGraphDisconnectNodeInput(graph, node, bus);
        if (status != noErr)
            return status;
    }
    return noErr;
}

OSStatus
AUGraphGetNumberOfInteractions(AUGraph graph, UInt32 *outCount)
{
    if (!graph || !outCount)
        return kAudio_ParamError;
    *outCount = (UInt32)graph->interactionCount;
    return noErr;
}

OSStatus
AUGraphGetInteractionInfo(AUGraph graph, UInt32 index, AUNodeInteraction *outInteraction)
{
    if (!graph || !outInteraction)
        return kAudio_ParamError;
    if (index >= graph->interactionCount)
        return kAUGraphErr_InvalidConnection;
    *outInteraction = graph->interactions[index];
    return noErr;
}

static Boolean
interaction_has_node(const AUNodeInteraction *item, AUNode node)
{
    return item->nodeInteractionType == kAUNodeInteraction_Connection
        ? item->nodeInteraction.connection.sourceNode == node || item->nodeInteraction.connection.destNode == node
        : item->nodeInteraction.inputCallback.destNode == node;
}

OSStatus
AUGraphCountNodeInteractions(AUGraph graph, AUNode node, UInt32 *outCount)
{
    if (!graph || !outCount)
        return kAudio_ParamError;
    if (!node_for(graph, node))
        return kAUGraphErr_NodeNotFound;
    UInt32 count = 0;
    for (size_t i = 0; i < graph->interactionCount; i++)
        if (interaction_has_node(&graph->interactions[i], node)) count++;
    *outCount = count;
    return noErr;
}

OSStatus
AUGraphGetNodeInteractions(AUGraph graph, AUNode node, UInt32 *ioCount, AUNodeInteraction *outItems)
{
    if (!graph || !ioCount || (!outItems && *ioCount))
        return kAudio_ParamError;
    if (!node_for(graph, node))
        return kAUGraphErr_NodeNotFound;
    UInt32 capacity = *ioCount, count = 0;
    for (size_t i = 0; i < graph->interactionCount; i++)
        if (interaction_has_node(&graph->interactions[i], node)) {
            if (count < capacity) outItems[count] = graph->interactions[i];
            count++;
        }
    *ioCount = count < capacity ? count : capacity;
    return count > capacity ? kAudio_ParamError : noErr;
}

OSStatus
AUGraphGetNumberOfConnections(AUGraph graph, UInt32 *outCount)
{
    if (!graph || !outCount)
        return kAudio_ParamError;
    UInt32 count = 0;
    for (size_t i = 0; i < graph->interactionCount; i++)
        if (graph->interactions[i].nodeInteractionType == kAUNodeInteraction_Connection) count++;
    *outCount = count;
    return noErr;
}

OSStatus
AUGraphGetConnectionInfo(AUGraph graph, UInt32 index, AUNode *source, UInt32 *sourceBus, AUNode *dest, UInt32 *destBus)
{
    if (!graph)
        return kAudio_ParamError;
    for (size_t i = 0, current = 0; i < graph->interactionCount; i++) {
        AUNodeInteraction *item = &graph->interactions[i];
        if (item->nodeInteractionType != kAUNodeInteraction_Connection) continue;
        if (current++ != index) continue;
        if (source) *source = item->nodeInteraction.connection.sourceNode;
        if (sourceBus) *sourceBus = item->nodeInteraction.connection.sourceOutputNumber;
        if (dest) *dest = item->nodeInteraction.connection.destNode;
        if (destBus) *destBus = item->nodeInteraction.connection.destInputNumber;
        return noErr;
    }
    return kAUGraphErr_InvalidConnection;
}

OSStatus
AUGraphCountNodeConnections(AUGraph graph, AUNode node, UInt32 *outCount)
{
    if (!graph || !outCount)
        return kAudio_ParamError;
    if (!node_for(graph, node))
        return kAUGraphErr_NodeNotFound;
    UInt32 count = 0;
    for (size_t i = 0; i < graph->interactionCount; i++)
        if (graph->interactions[i].nodeInteractionType == kAUNodeInteraction_Connection &&
            interaction_has_node(&graph->interactions[i], node)) count++;
    *outCount = count;
    return noErr;
}

OSStatus
AUGraphGetNodeConnections(AUGraph graph, AUNode node, AudioUnitNodeConnection *outConnections, UInt32 *ioCount)
{
    if (!graph || !ioCount || (!outConnections && *ioCount))
        return kAudio_ParamError;
    if (!node_for(graph, node))
        return kAUGraphErr_NodeNotFound;
    UInt32 capacity = *ioCount, count = 0;
    for (size_t i = 0; i < graph->interactionCount; i++) {
        AUNodeInteraction *item = &graph->interactions[i];
        if (item->nodeInteractionType != kAUNodeInteraction_Connection || !interaction_has_node(item, node)) continue;
        if (count < capacity) outConnections[count] = item->nodeInteraction.connection;
        count++;
    }
    *ioCount = count < capacity ? count : capacity;
    return count > capacity ? kAudio_ParamError : noErr;
}

static OSStatus
apply_notifiers(AUGraph graph)
{
    AudioUnit target = NULL;
    for (size_t i = 0; i < graph->nodeCount; i++)
        if (graph->nodes[i].unit && graph->nodes[i].isOutput) { target = graph->nodes[i].unit; break; }
    if (!target)
        for (size_t i = 0; i < graph->nodeCount; i++)
            if (graph->nodes[i].unit) { target = graph->nodes[i].unit; break; }
    if (!target)
        return noErr;
    for (size_t i = 0; i < graph->notifierCount; i++) {
        OSStatus status = AudioUnitAddRenderNotify(target, graph->notifiers[i].callback, graph->notifiers[i].refCon);
        if (status != noErr)
            return status;
    }
    return noErr;
}

OSStatus
AUGraphOpen(AUGraph graph)
{
    if (!graph)
        return kAudio_ParamError;
    if (graph->open)
        return noErr;
    for (size_t i = 0; i < graph->nodeCount; i++) {
        FinchGraphNode *node = &graph->nodes[i];
        if (node->subgraph) {
            OSStatus status = AUGraphOpen(node->subgraph);
            if (status != noErr) goto fail;
            continue;
        }
        AudioComponent component = AudioComponentFindNext(NULL, &node->description);
        if (!component || AudioComponentInstanceNew(component, &node->unit) != noErr)
            goto fail;
    }
    graph->open = true;
    for (size_t i = 0; i < graph->interactionCount; i++) {
        OSStatus status = install_interaction(graph, &graph->interactions[i]);
        if (status != noErr) { AUGraphClose(graph); return status; }
    }
    OSStatus status = apply_notifiers(graph);
    if (status != noErr) { AUGraphClose(graph); return status; }
    return noErr;
fail:
    for (size_t i = 0; i < graph->nodeCount; i++) {
        if (graph->nodes[i].unit) {
            AudioComponentInstanceDispose(graph->nodes[i].unit);
            graph->nodes[i].unit = NULL;
        }
    }
    return kAUGraphErr_InvalidAudioUnit;
}

OSStatus
AUGraphClose(AUGraph graph)
{
    if (!graph)
        return kAudio_ParamError;
    if (graph->running)
        AUGraphStop(graph);
    if (graph->initialized)
        AUGraphUninitialize(graph);
    for (size_t i = 0; i < graph->nodeCount; i++) {
        if (graph->nodes[i].unit) {
            for (size_t j = 0; j < graph->notifierCount; j++)
                AudioUnitRemoveRenderNotify(graph->nodes[i].unit, graph->notifiers[j].callback, graph->notifiers[j].refCon);
            AudioComponentInstanceDispose(graph->nodes[i].unit);
            graph->nodes[i].unit = NULL;
        }
        if (graph->nodes[i].subgraph)
            AUGraphClose(graph->nodes[i].subgraph);
    }
    graph->open = false;
    graph->initialized = false;
    graph->running = false;
    return noErr;
}

OSStatus
AUGraphInitialize(AUGraph graph)
{
    if (!graph)
        return kAudio_ParamError;
    if (!graph->open) {
        OSStatus status = AUGraphOpen(graph);
        if (status != noErr)
            return status;
    }
    if (graph->initialized)
        return noErr;
    for (size_t i = 0; i < graph->nodeCount; i++) {
        OSStatus status = graph->nodes[i].subgraph ? AUGraphInitialize(graph->nodes[i].subgraph)
            : graph->nodes[i].unit ? AudioUnitInitialize(graph->nodes[i].unit) : noErr;
        if (status != noErr) {
            for (size_t j = 0; j < i; j++)
                if (graph->nodes[j].unit) AudioUnitUninitialize(graph->nodes[j].unit);
            return status;
        }
    }
    graph->initialized = true;
    return noErr;
}

OSStatus
AUGraphUninitialize(AUGraph graph)
{
    if (!graph)
        return kAudio_ParamError;
    if (graph->running)
        AUGraphStop(graph);
    for (size_t i = graph->nodeCount; i > 0; i--) {
        FinchGraphNode *node = &graph->nodes[i - 1];
        if (node->subgraph)
            AUGraphUninitialize(node->subgraph);
        else if (node->unit)
            AudioUnitUninitialize(node->unit);
    }
    graph->initialized = false;
    return noErr;
}

OSStatus
AUGraphStart(AUGraph graph)
{
    if (!graph)
        return kAudio_ParamError;
    if (!graph->initialized)
        return kAudioUnitErr_Uninitialized;
    for (size_t i = 0; i < graph->nodeCount; i++) {
        FinchGraphNode *node = &graph->nodes[i];
        if (node->subgraph) {
            OSStatus status = AUGraphStart(node->subgraph);
            if (status != noErr) return status;
        } else if (node->unit && node->isOutput) {
            OSStatus status = AudioOutputUnitStart(node->unit);
            if (status != noErr) return status;
        }
    }
    graph->running = true;
    return noErr;
}

OSStatus
AUGraphStop(AUGraph graph)
{
    if (!graph)
        return kAudio_ParamError;
    OSStatus result = noErr;
    for (size_t i = graph->nodeCount; i > 0; i--) {
        FinchGraphNode *node = &graph->nodes[i - 1];
        OSStatus status = noErr;
        if (node->subgraph)
            status = AUGraphStop(node->subgraph);
        else if (node->unit && node->isOutput)
            status = AudioOutputUnitStop(node->unit);
        if (result == noErr && status != noErr) result = status;
    }
    graph->running = false;
    return result;
}

OSStatus
AUGraphIsOpen(AUGraph graph, Boolean *outValue)
{
    if (!graph || !outValue) return kAudio_ParamError;
    *outValue = graph->open;
    return noErr;
}

OSStatus
AUGraphIsInitialized(AUGraph graph, Boolean *outValue)
{
    if (!graph || !outValue) return kAudio_ParamError;
    *outValue = graph->initialized;
    return noErr;
}

OSStatus
AUGraphIsRunning(AUGraph graph, Boolean *outValue)
{
    if (!graph || !outValue) return kAudio_ParamError;
    *outValue = graph->running;
    return noErr;
}

OSStatus
AUGraphUpdate(AUGraph graph, Boolean *outUpdated)
{
    if (!graph) return kAudio_ParamError;
    if (outUpdated) *outUpdated = true;
    return noErr;
}

OSStatus
AUGraphGetCPULoad(AUGraph graph, Float32 *outLoad)
{
    if (!graph || !outLoad) return kAudio_ParamError;
    *outLoad = 0;
    return noErr;
}

OSStatus
AUGraphGetMaxCPULoad(AUGraph graph, Float32 *outLoad)
{
    if (!graph || !outLoad) return kAudio_ParamError;
    *outLoad = 0;
    return noErr;
}

OSStatus
AUGraphAddRenderNotify(AUGraph graph, AURenderCallback callback, void *refCon)
{
    if (!graph || !callback) return kAudio_ParamError;
    OSStatus status = reserve_notifiers(graph);
    if (status != noErr) return status;
    if (graph->open) {
        AudioUnit target = NULL;
        for (size_t i = 0; i < graph->nodeCount; i++)
            if (graph->nodes[i].unit && graph->nodes[i].isOutput) { target = graph->nodes[i].unit; break; }
        if (!target)
            for (size_t i = 0; i < graph->nodeCount; i++)
                if (graph->nodes[i].unit) { target = graph->nodes[i].unit; break; }
        if (target) {
            status = AudioUnitAddRenderNotify(target, callback, refCon);
            if (status != noErr) return status;
        }
    }
    graph->notifiers[graph->notifierCount++] = (FinchRenderNotify){callback, refCon};
    return noErr;
}

OSStatus
AUGraphRemoveRenderNotify(AUGraph graph, AURenderCallback callback, void *refCon)
{
    if (!graph || !callback) return kAudio_ParamError;
    size_t index = 0;
    while (index < graph->notifierCount && (graph->notifiers[index].callback != callback || graph->notifiers[index].refCon != refCon)) index++;
    if (index == graph->notifierCount) return kAudio_ParamError;
    if (graph->open)
        for (size_t i = 0; i < graph->nodeCount; i++)
            if (graph->nodes[i].unit) AudioUnitRemoveRenderNotify(graph->nodes[i].unit, callback, refCon);
    memmove(&graph->notifiers[index], &graph->notifiers[index + 1], (graph->notifierCount - index - 1) * sizeof(*graph->notifiers));
    graph->notifierCount--;
    return noErr;
}
